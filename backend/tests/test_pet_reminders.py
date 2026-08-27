"""宠物日常 due reminders and plugin preview."""

import uuid
from datetime import date

from httpx import AsyncClient

from app.core.database import async_session_maker
from app.plugins.pet.reminders import check_due_pet_plans

BASE = "/api/v1/families/{fid}/plugins/pet"


async def _setup(client: AsyncClient, *, installed: bool) -> tuple[str, dict, dict]:
    family = await client.post(
        "/api/v1/families", json={"name": f"宠物提醒-{uuid.uuid4().hex[:8]}"}
    )
    family_id = family.json()["data"]["id"]
    if installed:
        result = await client.post(
            f"/api/v1/families/{family_id}/plugins", json={"plugin_id": "pet"}
        )
        assert result.status_code == 201, result.text
    pet = (
        await client.post(
            f"/api/v1/families/{family_id}/pets", json={"name": "团子", "emoji": "🐈"}
        )
    ).json()["data"]
    types = (await client.get(f"{BASE.format(fid=family_id)}/record-types")).json()["data"]
    deworm = next(item for item in types if item["name"] == "驱虫")
    plan = (
        await client.post(
            f"{BASE.format(fid=family_id)}/pets/{pet['id']}/plans",
            json={
                "record_type_id": deworm["id"],
                "name": "体内驱虫",
                "recurrence_unit": "month",
                "recurrence_interval": 3,
                "next_due_date": "2026-08-14",
            },
        )
    ).json()["data"]
    return family_id, pet, plan


async def _notice_count(client: AsyncClient, family_id: str) -> int:
    notifications = (await client.get("/api/v1/notifications")).json()["data"]
    return len(
        [
            item
            for item in notifications
            if item.get("type") == "pet_care_due" and item.get("family_id") == family_id
        ]
    )


async def test_due_reminder_is_idempotent_and_preview_shows_urgent_plan(
    client: AsyncClient,
) -> None:
    family_id, _pet, _plan = await _setup(client, installed=True)
    async with async_session_maker() as session:
        await check_due_pet_plans(session, today=date(2026, 8, 14))
    async with async_session_maker() as session:
        await check_due_pet_plans(session, today=date(2026, 8, 14))
    assert await _notice_count(client, family_id) == 1

    installed = (await client.get(f"/api/v1/families/{family_id}/plugins")).json()["data"]
    preview = next(item for item in installed if item["plugin_id"] == "pet")["preview"]
    assert "体内驱虫" in preview["primary"]


async def test_uninstalled_family_is_skipped(client: AsyncClient) -> None:
    family_id, _pet, _plan = await _setup(client, installed=False)
    async with async_session_maker() as session:
        await check_due_pet_plans(session, today=date(2026, 8, 15))
    assert await _notice_count(client, family_id) == 0


async def test_preview_without_pets_has_explicit_empty_state(client: AsyncClient) -> None:
    family = await client.post(
        "/api/v1/families", json={"name": f"宠物空态-{uuid.uuid4().hex[:8]}"}
    )
    family_id = family.json()["data"]["id"]
    await client.post(f"/api/v1/families/{family_id}/plugins", json={"plugin_id": "pet"})
    installs = (await client.get(f"/api/v1/families/{family_id}/plugins")).json()["data"]
    preview = next(item for item in installs if item["plugin_id"] == "pet")["preview"]
    assert preview["primary"] == "还没有宠物"


async def test_uninstall_and_reinstall_preserves_pet_daily_data(client: AsyncClient) -> None:
    family_id, pet, plan = await _setup(client, installed=True)
    installs = (await client.get(f"/api/v1/families/{family_id}/plugins")).json()["data"]
    install = next(item for item in installs if item["plugin_id"] == "pet")
    removed = await client.delete(f"/api/v1/families/{family_id}/plugins/{install['id']}")
    assert removed.status_code == 200

    async with async_session_maker() as session:
        await check_due_pet_plans(session, today=date(2026, 8, 15))
    assert await _notice_count(client, family_id) == 0

    reinstalled = await client.post(
        f"/api/v1/families/{family_id}/plugins", json={"plugin_id": "pet"}
    )
    assert reinstalled.status_code == 201, reinstalled.text
    dashboard = await client.get(f"{BASE.format(fid=family_id)}/pets/{pet['id']}")
    assert dashboard.status_code == 200
    assert dashboard.json()["data"]["pet"]["id"] == pet["id"]
    assert dashboard.json()["data"]["today_plans"][0]["id"] == plan["id"]
