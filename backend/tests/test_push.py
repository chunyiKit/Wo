"""Push: JPush payload shaping, unconfigured no-op, and outbox dispatch."""

import uuid

import pytest
from httpx import AsyncClient
from sqlmodel import select

from app.core import config
from app.core.database import async_session_maker
from app.core.ids import SEED_USER_ID, SEED_USER_ID_3
from app.models.notification import Notification
from app.models.push_outbox import PushOutbox
from app.services import device_token as device_service
from app.services.push import JPushClient, PushMessage, build_jpush_payload
from app.services.push_dispatcher import dispatch_pending


def _reg_id() -> str:
    return f"reg-{uuid.uuid4().hex[:16]}"


# ---- JPush client (no network) --------------------------------------------


def test_build_jpush_payload_carries_audience_and_extras() -> None:
    msg = PushMessage(
        registration_ids=["a", "b"],
        title="标题",
        body="正文",
        extras={"deeplink": "wo://family/x/members", "type": "member_joined"},
    )
    payload = build_jpush_payload(msg, apns_production=False)

    assert payload["audience"]["registration_id"] == ["a", "b"]
    assert payload["notification"]["android"]["title"] == "标题"
    assert payload["notification"]["ios"]["alert"] == {"title": "标题", "body": "正文"}
    assert payload["notification"]["ios"]["extras"]["deeplink"] == "wo://family/x/members"
    assert payload["options"]["apns_production"] is False


async def test_unconfigured_client_is_noop() -> None:
    client = JPushClient(app_key="", master_secret="", api_url="http://x", apns_production=False)
    assert client.configured is False
    # Must not raise nor hit the network when credentials are absent.
    await client.send_push(PushMessage(registration_ids=["a"], title="t", body="b"))


# ---- Notifier → outbox staging (real insertion point) ----------------------


async def test_notification_stages_outbox_when_push_enabled(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Accepting an invite emits member_joined to the owner; with push enabled
    that must also stage a matching push_outbox row in the same transaction."""
    monkeypatch.setattr(config.settings, "push_enabled", True)

    fam = await client.post("/api/v1/families", json={"name": f"推送-{uuid.uuid4().hex[:8]}"})
    fid = fam.json()["data"]["id"]
    invite = (
        await client.post(f"/api/v1/families/{fid}/invitations", json={"role": "member"})
    ).json()["data"]
    accept = await client.post(
        f"/api/v1/invitations/{invite['code']}/accept",
        headers={"X-User-Id": "019000a0-1100-7000-8000-000000000002"},
    )
    assert accept.status_code == 200, accept.text

    # The owner's member_joined notification for this family must have an outbox row.
    async with async_session_maker() as session:
        notif = (
            await session.execute(
                select(Notification).where(
                    Notification.user_id == SEED_USER_ID,
                    Notification.type == "member_joined",
                    Notification.family_id == uuid.UUID(fid),
                )
            )
        ).scalar_one()
        outbox = (
            await session.execute(select(PushOutbox).where(PushOutbox.notification_id == notif.id))
        ).scalar_one_or_none()
        assert outbox is not None, "push-enabled notification should stage an outbox row"
        assert outbox.status == "pending"


# ---- Outbox dispatch -------------------------------------------------------


async def test_dispatch_sends_to_device_tokens_and_marks_sent(client: AsyncClient) -> None:
    """client fixture guarantees the lifespan/seed ran so SEED_USER_ID exists."""
    rid = _reg_id()
    sent: list[PushMessage] = []

    async def fake_sender(message: PushMessage) -> None:
        sent.append(message)

    async with async_session_maker() as session:
        await device_service.register_device(
            session, user_id=SEED_USER_ID, registration_id=rid, platform="android"
        )
        notif = Notification(
            user_id=SEED_USER_ID,
            type="test_push",
            title="测试推送",
            body="正文",
            deeplink="wo://test",
        )
        session.add(notif)
        outbox = PushOutbox(notification_id=notif.id)
        session.add(outbox)
        await session.commit()
        notif_id = str(notif.id)
        outbox_id = outbox.id

    async with async_session_maker() as session:
        processed = await dispatch_pending(session, fake_sender, batch_size=500)

    assert processed >= 1
    # Our message was delivered to our device token, with the deep-link extra.
    # Match on notification_id (the suite may have other pending rows for the
    # same seed user / token in the shared DB).
    ours = [m for m in sent if m.extras.get("notification_id") == notif_id]
    assert len(ours) == 1
    assert rid in ours[0].registration_ids
    assert ours[0].extras["deeplink"] == "wo://test"

    async with async_session_maker() as session:
        row = await session.get(PushOutbox, outbox_id)
        assert row is not None
        assert row.status == "sent"
        assert row.sent_at is not None


async def test_dispatch_settles_row_when_recipient_has_no_device(client: AsyncClient) -> None:
    sent: list[PushMessage] = []

    async def fake_sender(message: PushMessage) -> None:
        sent.append(message)

    # 小宝 (SEED_USER_ID_3) never registers a device in the suite, so the
    # dispatcher should settle the row without calling the sender for it.
    async with async_session_maker() as session:
        notif = Notification(user_id=SEED_USER_ID_3, type="test_push", title="t", body="b")
        session.add(notif)
        outbox = PushOutbox(notification_id=notif.id)
        session.add(outbox)
        await session.commit()
        notif_id = str(notif.id)
        outbox_id = outbox.id

    async with async_session_maker() as session:
        await dispatch_pending(session, fake_sender, batch_size=500)

    # No push was attempted for this notification (recipient has no device).
    assert all(m.extras.get("notification_id") != notif_id for m in sent)

    async with async_session_maker() as session:
        row = await session.get(PushOutbox, outbox_id)
        assert row is not None
        # Settled (nothing to deliver to) — never left pending to reprocess.
        assert row.status == "sent"


async def test_dispatch_retries_then_fails_after_max_attempts(client: AsyncClient) -> None:
    rid = _reg_id()

    async def failing_sender(message: PushMessage) -> None:
        raise RuntimeError("provider down")

    async with async_session_maker() as session:
        await device_service.register_device(
            session, user_id=SEED_USER_ID, registration_id=rid, platform="ios"
        )
        notif = Notification(user_id=SEED_USER_ID, type="test_push", title="t", body="b")
        session.add(notif)
        outbox = PushOutbox(notification_id=notif.id)
        session.add(outbox)
        await session.commit()
        outbox_id = outbox.id

    # First pass: one failed attempt, still pending (max_attempts=2).
    async with async_session_maker() as session:
        await dispatch_pending(session, failing_sender, batch_size=500, max_attempts=2)
    async with async_session_maker() as session:
        row = await session.get(PushOutbox, outbox_id)
        assert row is not None and row.status == "pending" and row.attempts == 1

    # Second pass: hits the cap and flips to failed.
    async with async_session_maker() as session:
        await dispatch_pending(session, failing_sender, batch_size=500, max_attempts=2)
    async with async_session_maker() as session:
        row = await session.get(PushOutbox, outbox_id)
        assert row is not None
        assert row.status == "failed"
        assert row.attempts == 2
        assert row.last_error and "provider down" in row.last_error
