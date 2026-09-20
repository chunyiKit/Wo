"""通知偏好：默认值、来源列表、读写，以及站内新消息与系统推送的统一过滤。"""

import random
import uuid
from datetime import date

import pytest
from httpx import AsyncClient
from sqlmodel import select

from app.core import config
from app.core.database import async_session_maker
from app.models.notification import Notification
from app.models.push_outbox import PushOutbox
from app.plugins.plant.models import Plant
from app.plugins.plant.reminders import check_due_plants
from app.services import device_token as device_service
from app.services import notification as notification_service
from app.services.notification_prefs import notification_allowed, source_key_for_type
from app.services.push_dispatcher import dispatch_pending


def _random_phone() -> str:
    return "1" + str(random.randint(3, 9)) + "".join(str(random.randint(0, 9)) for _ in range(9))


async def _register_user(client: AsyncClient) -> dict[str, str]:
    res = await client.post(
        "/api/v1/auth/login",
        json={"phone": _random_phone(), "password": "secret123"},
    )
    return {"X-User-Id": res.json()["data"]["user"]["id"]}


async def _new_family(client: AsyncClient, headers: dict[str, str]) -> str:
    fam = await client.post(
        "/api/v1/families",
        json={"name": f"窝-{uuid.uuid4().hex[:8]}"},
        headers=headers,
    )
    fid = fam.json()["data"]["id"]
    # 确保它是当前家庭（来源列表按当前家庭的已安装插件计算）。
    await client.post(f"/api/v1/families/{fid}/switch", headers=headers)
    return fid


# ---- 纯函数单元 ------------------------------------------------------------


def test_source_key_for_type_maps_platform_and_plugins() -> None:
    assert source_key_for_type("member_joined") == "family"
    assert source_key_for_type("ownership_transferred") == "family"
    assert source_key_for_type("anniversary_due") == "anniversary"
    assert source_key_for_type("accounting_month_end") == "accounting"
    assert source_key_for_type("chore_assigned") == "chore"
    assert source_key_for_type("chore_reminder") == "chore"


def test_notification_allowed_defaults_and_toggles() -> None:
    # 空偏好 = 全部允许（opt-out）。
    assert notification_allowed({}, "anniversary_due") is True
    assert notification_allowed(None, "member_joined") is True
    # 总开关关闭 = 一律不推。
    assert notification_allowed({"push_enabled": False}, "anniversary_due") is False
    # 单来源关闭只影响该来源。
    prefs = {"push_enabled": True, "sources": {"chore": False}}
    assert notification_allowed(prefs, "chore_assigned") is False
    assert notification_allowed(prefs, "anniversary_due") is True


# ---- 接口：默认值与来源列表 ------------------------------------------------


async def test_prefs_default_only_family_source(client: AsyncClient) -> None:
    headers = await _register_user(client)  # 新用户，无家庭
    res = await client.get("/api/v1/me/notification-preferences", headers=headers)
    assert res.status_code == 200, res.text
    data = res.json()["data"]
    assert data["push_enabled"] is True
    assert [s["key"] for s in data["sources"]] == ["family"]
    assert all(s["enabled"] for s in data["sources"])


async def test_sources_include_installed_plugins_with_notifications(
    client: AsyncClient,
) -> None:
    headers = await _register_user(client)
    fid = await _new_family(client, headers)
    # chore 有通知机制；recipe 没有。
    await client.post(
        f"/api/v1/families/{fid}/plugins", json={"plugin_id": "chore"}, headers=headers
    )
    await client.post(
        f"/api/v1/families/{fid}/plugins", json={"plugin_id": "recipe"}, headers=headers
    )
    res = await client.get("/api/v1/me/notification-preferences", headers=headers)
    keys = [s["key"] for s in res.json()["data"]["sources"]]
    assert "family" in keys
    assert "chore" in keys
    assert "recipe" not in keys


# ---- 接口：读写 ------------------------------------------------------------


async def test_patch_push_enabled_persists(client: AsyncClient) -> None:
    headers = await _register_user(client)
    res = await client.patch(
        "/api/v1/me/notification-preferences",
        json={"push_enabled": False},
        headers=headers,
    )
    assert res.json()["data"]["push_enabled"] is False
    again = await client.get("/api/v1/me/notification-preferences", headers=headers)
    assert again.json()["data"]["push_enabled"] is False


async def test_patch_sources_is_partial(client: AsyncClient) -> None:
    headers = await _register_user(client)
    await client.patch(
        "/api/v1/me/notification-preferences",
        json={"sources": {"family": False}},
        headers=headers,
    )
    # 再关一个别的来源，不应覆盖前一次的 family=False。
    res = await client.patch(
        "/api/v1/me/notification-preferences",
        json={"sources": {"chore": False}},
        headers=headers,
    )
    by_key = {s["key"]: s["enabled"] for s in res.json()["data"]["sources"]}
    assert by_key["family"] is False


# ---- 通知过滤：偏好同时控制 Notification 与 PushOutbox ---------------------


@pytest.mark.parametrize("server_push_enabled", [False, True])
@pytest.mark.parametrize("prefs", [{"sources": {"family": False}}, {"push_enabled": False}])
async def test_muted_notifications_skip_inapp_and_outbox(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
    server_push_enabled: bool,
    prefs: dict,
) -> None:
    monkeypatch.setattr(config.settings, "push_enabled", server_push_enabled)

    owner = await _register_user(client)
    # 用户关闭总开关或来源，无论服务器是否启用推送都不能生成站内新消息。
    await client.patch(
        "/api/v1/me/notification-preferences",
        json=prefs,
        headers=owner,
    )
    fid = await _new_family(client, owner)
    invite = (
        await client.post(
            f"/api/v1/families/{fid}/invitations", json={"role": "member"}, headers=owner
        )
    ).json()["data"]

    joiner = await _register_user(client)
    accept = await client.post(f"/api/v1/invitations/{invite['code']}/accept", headers=joiner)
    assert accept.status_code == 200, accept.text

    owner_id = uuid.UUID(owner["X-User-Id"])
    async with async_session_maker() as session:
        notif = (
            await session.execute(
                select(Notification).where(
                    Notification.user_id == owner_id,
                    Notification.type == "member_joined",
                    Notification.family_id == uuid.UUID(fid),
                )
            )
        ).scalar_one_or_none()
        assert notif is None
        outbox = (
            await session.execute(
                select(PushOutbox)
                .join(Notification, Notification.id == PushOutbox.notification_id)
                .where(Notification.user_id == owner_id)
            )
        ).scalar_one_or_none()
        assert outbox is None


async def test_unmuted_source_still_stages_outbox(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(config.settings, "push_enabled", True)

    owner = await _register_user(client)  # 默认全部允许
    fid = await _new_family(client, owner)
    invite = (
        await client.post(
            f"/api/v1/families/{fid}/invitations", json={"role": "member"}, headers=owner
        )
    ).json()["data"]
    joiner = await _register_user(client)
    await client.post(f"/api/v1/invitations/{invite['code']}/accept", headers=joiner)

    owner_id = uuid.UUID(owner["X-User-Id"])
    async with async_session_maker() as session:
        notif = (
            await session.execute(
                select(Notification).where(
                    Notification.user_id == owner_id,
                    Notification.type == "member_joined",
                    Notification.family_id == uuid.UUID(fid),
                )
            )
        ).scalar_one()
        outbox = (
            await session.execute(select(PushOutbox).where(PushOutbox.notification_id == notif.id))
        ).scalar_one_or_none()
        assert outbox is not None
        assert outbox.status == "pending"


async def test_plant_mute_keeps_history_and_other_members_receiving(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(config.settings, "push_enabled", True)
    owner = await _register_user(client)
    member = await _register_user(client)
    fid = await _new_family(client, owner)
    invite = (
        await client.post(
            f"/api/v1/families/{fid}/invitations",
            json={"role": "member"},
            headers=owner,
        )
    ).json()["data"]
    accepted = await client.post(
        f"/api/v1/invitations/{invite['code']}/accept",
        headers=member,
    )
    assert accepted.status_code == 200
    owner_id = uuid.UUID(owner["X-User-Id"])
    member_id = uuid.UUID(member["X-User-Id"])
    family_id = uuid.UUID(fid)
    async with async_session_maker() as session:
        await notification_service.notify_users(
            session,
            recipients=[owner_id],
            family_id=family_id,
            notification_type="plant_water_due",
            title="历史浇水提醒",
            body="历史",
        )
        await session.commit()
    muted = await client.patch(
        "/api/v1/me/notification-preferences",
        json={"sources": {"plant": False}},
        headers=owner,
    )
    assert muted.status_code == 200

    async with async_session_maker() as session:
        unread_before = await notification_service.count_unread(session, owner_id)
        plant = Plant(
            family_id=family_id,
            name="蓝雪花",
            water_interval_days=2,
            fert_interval_days=7,
            next_water_due=date.today(),
            next_fert_due=date.today(),
        )
        session.add(plant)
        await session.commit()
        await check_due_plants(session, today=date.today())
        await session.refresh(plant)
        assert plant.next_water_due > date.today()
        assert plant.next_fert_due > date.today()
        notes = list(
            (
                await session.execute(
                    select(Notification).where(
                        Notification.family_id == family_id,
                        Notification.type.like("plant_%"),
                    )
                )
            )
            .scalars()
            .all()
        )
        assert [n.title for n in notes if n.user_id == owner_id] == ["历史浇水提醒"]
        assert {n.type for n in notes if n.user_id == member_id} == {
            "plant_water_due",
            "plant_fert_due",
        }
        assert await notification_service.count_unread(session, owner_id) == unread_before
        # 同一用户的其他来源照常接收，显式接收者入口也遵循偏好。
        assert (
            await notification_service.notify_users(
                session,
                recipients=[owner_id],
                family_id=family_id,
                notification_type="accounting_month_end",
                title="记账提醒",
                body="记账",
            )
            == 1
        )
        assert (
            await notification_service.notify_users(
                session,
                recipients=[owner_id],
                family_id=family_id,
                notification_type="plant_fert_due",
                title="静音提醒",
                body="静音",
            )
            == 0
        )
        await session.commit()

    # 历史消息仍可见，关闭期间没有增加植物提醒。
    inbox = (await client.get("/api/v1/notifications", headers=owner)).json()["data"]
    assert [n["title"] for n in inbox if n["type"].startswith("plant_")] == ["历史浇水提醒"]
    unmuted = await client.patch(
        "/api/v1/me/notification-preferences",
        json={"sources": {"plant": True}},
        headers=owner,
    )
    assert unmuted.status_code == 200
    async with async_session_maker() as session:
        assert (
            await notification_service.notify_users(
                session,
                recipients=[owner_id],
                family_id=family_id,
                notification_type="plant_water_due",
                title="重新开启后的提醒",
                body="浇水",
            )
            == 1
        )
        await session.commit()
    inbox = (await client.get("/api/v1/notifications", headers=owner)).json()["data"]
    assert len([n for n in inbox if n["type"].startswith("plant_")]) == 2


@pytest.mark.parametrize("prefs", [{"sources": {"plant": False}}, {"push_enabled": False}])
async def test_mute_cancels_pending_push_but_keeps_history(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
    prefs: dict,
) -> None:
    monkeypatch.setattr(config.settings, "push_enabled", True)
    user = await _register_user(client)
    uid = uuid.UUID(user["X-User-Id"])
    async with async_session_maker() as session:
        await device_service.register_device(
            session,
            user_id=uid,
            registration_id=f"reg-{uuid.uuid4().hex}",
            platform="android",
        )
        await notification_service.notify_users(
            session,
            recipients=[uid],
            family_id=None,
            notification_type="plant_water_due",
            title="已入队提醒",
            body="浇水",
        )
        await session.commit()
    response = await client.patch(
        "/api/v1/me/notification-preferences",
        json=prefs,
        headers=user,
    )
    assert response.status_code == 200
    sent = []

    async def fake_sender(message):
        sent.append(message)

    async with async_session_maker() as session:
        note = (
            await session.execute(
                select(Notification).where(
                    Notification.user_id == uid,
                )
            )
        ).scalar_one()
        await dispatch_pending(session, fake_sender, batch_size=10000)
        row = (
            await session.execute(
                select(PushOutbox).where(
                    PushOutbox.notification_id == note.id,
                )
            )
        ).scalar_one()
        assert row.status == "sent"  # 现有状态表示队列处理结束，也包含无需发送。
        assert row.attempts == 0
        assert not any(m.extras.get("notification_id") == str(note.id) for m in sent)
