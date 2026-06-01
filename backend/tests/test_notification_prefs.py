"""通知偏好：默认值、来源列表、读写，以及对系统推送（push_outbox）的过滤。"""

import random
import uuid

import pytest
from httpx import AsyncClient
from sqlmodel import select

from app.core import config
from app.core.database import async_session_maker
from app.models.notification import Notification
from app.models.push_outbox import PushOutbox
from app.services.notification_prefs import push_allowed, source_key_for_type


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


def test_push_allowed_defaults_and_toggles() -> None:
    # 空偏好 = 全部允许（opt-out）。
    assert push_allowed({}, "anniversary_due") is True
    assert push_allowed(None, "member_joined") is True
    # 总开关关闭 = 一律不推。
    assert push_allowed({"push_enabled": False}, "anniversary_due") is False
    # 单来源关闭只影响该来源。
    prefs = {"push_enabled": True, "sources": {"chore": False}}
    assert push_allowed(prefs, "chore_assigned") is False
    assert push_allowed(prefs, "anniversary_due") is True


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


# ---- 推送过滤：偏好决定是否进 push_outbox ----------------------------------


async def test_muted_source_skips_outbox_but_keeps_inapp(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(config.settings, "push_enabled", True)

    owner = await _register_user(client)
    # owner 关闭「家庭与成员动态」推送。
    await client.patch(
        "/api/v1/me/notification-preferences",
        json={"sources": {"family": False}},
        headers=owner,
    )
    fid = await _new_family(client, owner)
    invite = (
        await client.post(
            f"/api/v1/families/{fid}/invitations", json={"role": "member"}, headers=owner
        )
    ).json()["data"]

    joiner = await _register_user(client)
    accept = await client.post(
        f"/api/v1/invitations/{invite['code']}/accept", headers=joiner
    )
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
        ).scalar_one()
        # 站内通知仍在。
        assert notif is not None
        # 但被静音，不进 push_outbox。
        outbox = (
            await session.execute(
                select(PushOutbox).where(PushOutbox.notification_id == notif.id)
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
            await session.execute(
                select(PushOutbox).where(PushOutbox.notification_id == notif.id)
            )
        ).scalar_one_or_none()
        assert outbox is not None
        assert outbox.status == "pending"
