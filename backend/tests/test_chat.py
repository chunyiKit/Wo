"""Chat plugin tests — sync window, media, push outbox, and retention cleanup."""

import uuid
from datetime import UTC, datetime, timedelta
from io import BytesIO

import pytest
from httpx import AsyncClient
from PIL import Image
from sqlmodel import select

from app.core import config
from app.core.database import async_session_maker
from app.core.ids import SEED_USER_ID, SEED_USER_ID_2, SEED_USER_ID_3, new_uuid7
from app.models.family import Family
from app.models.user import User
from app.plugins.chat.cleanup import cleanup_expired_chat
from app.plugins.chat.models import ChatImage, ChatMessage, ChatPushOutbox

XIAOLIN = {"X-User-Id": str(SEED_USER_ID_2)}
XIAOBAO = {"X-User-Id": str(SEED_USER_ID_3)}

CHAT_BASE = "/api/v1/families/{fid}/plugins/chat/messages"


@pytest.fixture
def png_bytes() -> bytes:
    img = Image.new("RGB", (80, 60), color=(220, 120, 80))
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _unique_name() -> str:
    return f"家聊测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


async def _family_with_xiaolin(client: AsyncClient) -> str:
    fid = await _create_family(client)
    invite = (
        await client.post(f"/api/v1/families/{fid}/invitations", json={"role": "member"})
    ).json()["data"]
    await client.post(f"/api/v1/invitations/{invite['code']}/accept", headers=XIAOLIN)
    return fid


async def test_chat_plugin_is_listed(client: AsyncClient) -> None:
    response = await client.get("/api/v1/plugins")
    assert response.status_code == 200
    ids = {p["id"] for p in response.json()["data"]}
    assert "chat" in ids


async def test_send_text_is_idempotent_and_lists_once(client: AsyncClient) -> None:
    fid = await _create_family(client)
    body = {"client_id": "client-text-1", "body": "今晚吃什么？"}
    first = await client.post(CHAT_BASE.format(fid=fid), json=body)
    second = await client.post(CHAT_BASE.format(fid=fid), json=body)
    assert first.status_code == 201, first.text
    assert second.status_code == 201, second.text
    assert second.json()["data"]["id"] == first.json()["data"]["id"]
    assert second.json()["data"]["sender_name"]

    listed = await client.get(CHAT_BASE.format(fid=fid))
    assert listed.status_code == 200, listed.text
    rows = listed.json()["data"]
    assert [r["body"] for r in rows] == ["今晚吃什么？"]


async def test_message_cursor_returns_only_newer_rows(client: AsyncClient) -> None:
    fid = await _create_family(client)
    first = (
        await client.post(
            CHAT_BASE.format(fid=fid),
            json={"client_id": "cursor-1", "body": "第一条"},
        )
    ).json()["data"]
    second = (
        await client.post(
            CHAT_BASE.format(fid=fid),
            json={"client_id": "cursor-2", "body": "第二条"},
        )
    ).json()["data"]

    page = await client.get(
        CHAT_BASE.format(fid=fid),
        params={"after_created_at": first["created_at"], "after_id": first["id"]},
    )
    assert page.status_code == 200, page.text
    rows = page.json()["data"]
    assert [r["id"] for r in rows] == [second["id"]]


async def test_upload_image_and_read_raw(client: AsyncClient, png_bytes: bytes) -> None:
    fid = await _create_family(client)
    sent = await client.post(
        f"{CHAT_BASE.format(fid=fid)}/image",
        data={"client_id": "image-1"},
        files={"file": ("chat.png", png_bytes, "image/png")},
    )
    assert sent.status_code == 201, sent.text
    message = sent.json()["data"]
    assert message["kind"] == "image"
    assert message["image"]["width"] == 80
    assert message["image"]["height"] == 60

    raw = await client.get(message["image"]["url"])
    assert raw.status_code == 200
    assert raw.content == png_bytes


async def test_non_member_cannot_read_chat(client: AsyncClient) -> None:
    fid = await _create_family(client)
    response = await client.get(CHAT_BASE.format(fid=fid), headers=XIAOBAO)
    assert response.status_code == 404


async def test_send_stages_chat_push_to_other_members_only(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(config.settings, "push_enabled", True)
    fid = await _family_with_xiaolin(client)
    async with async_session_maker() as session:
        user = await session.get(User, SEED_USER_ID_2)
        assert user is not None
        user.notification_prefs = {"push_enabled": True, "sources": {"chat": True}}
        session.add(user)
        await session.commit()

    sent = (
        await client.post(
            CHAT_BASE.format(fid=fid),
            json={"client_id": "push-1", "body": "看手机"},
        )
    ).json()["data"]

    async with async_session_maker() as session:
        rows = list(
            (
                await session.execute(
                    select(ChatPushOutbox).where(ChatPushOutbox.message_id == uuid.UUID(sent["id"]))
                )
            )
            .scalars()
            .all()
        )
        assert {r.user_id for r in rows} == {SEED_USER_ID_2}


async def test_chat_push_respects_notification_preferences(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(config.settings, "push_enabled", True)
    fid = await _family_with_xiaolin(client)
    async with async_session_maker() as session:
        user = await session.get(User, SEED_USER_ID_2)
        assert user is not None
        user.notification_prefs = {"push_enabled": True, "sources": {"chat": False}}
        session.add(user)
        await session.commit()

    sent = (
        await client.post(
            CHAT_BASE.format(fid=fid),
            json={"client_id": "push-muted", "body": "静音消息"},
        )
    ).json()["data"]

    async with async_session_maker() as session:
        row = (
            await session.execute(
                select(ChatPushOutbox).where(ChatPushOutbox.message_id == uuid.UUID(sent["id"]))
            )
        ).scalar_one_or_none()
        assert row is None


async def test_cleanup_deletes_expired_messages_and_images(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class _FakeStorage:
        def __init__(self) -> None:
            self.deleted: list[str] = []

        async def delete(self, key: str) -> None:
            self.deleted.append(key)

    fake = _FakeStorage()
    from app.plugins.chat import cleanup as chat_cleanup

    monkeypatch.setattr(chat_cleanup, "storage", fake)

    fid = new_uuid7()
    msg_id = new_uuid7()
    old = datetime.now(UTC) - timedelta(days=config.settings.chat_retention_days + 1)

    async with async_session_maker() as session:
        session.add(Family(id=fid, name="清理测试", emoji="🏡"))
        await session.flush()
        message = ChatMessage(
            id=msg_id,
            family_id=fid,
            sender_id=SEED_USER_ID,
            client_id="expired",
            kind="image",
            sender_name="老陈",
            sender_emoji="👨",
            created_at=old,
        )
        session.add(message)
        await session.flush()
        image = ChatImage(
            message_id=msg_id,
            family_id=fid,
            storage_key="chat/expired/image.jpg",
            content_type="image/jpeg",
            size_bytes=12,
            created_at=old,
        )
        session.add(image)
        await session.commit()

    async with async_session_maker() as session:
        deleted = await cleanup_expired_chat(session)
    assert deleted >= 1
    assert fake.deleted == ["chat/expired/image.jpg"]

    async with async_session_maker() as session:
        assert await session.get(ChatMessage, msg_id) is None
