"""Plant watering/fertilizing reminders: fires on/after the due date, once per
due date (idempotent), and rolls the due date forward by the interval.

`check_due_plants` scans all families in one pass (like the other reminder
loops), so assertions filter notifications by this test's family rather than
relying on the global return count (which other tests' plants pollute)."""

import uuid
from datetime import date, timedelta

from httpx import AsyncClient

from app.core.database import async_session_maker
from app.plugins.plant.reminders import check_due_plants

BASE = "/api/v1/families/{fid}/plugins/plant"


async def _create_family(client: AsyncClient) -> str:
    resp = await client.post(
        "/api/v1/families", json={"name": f"提醒测试-{uuid.uuid4().hex[:6]}"}
    )
    return resp.json()["data"]["id"]


async def _plant_with_water_cycle(client: AsyncClient, fid: str, days: int) -> dict:
    return (
        await client.post(
            f"{BASE.format(fid=fid)}/plants",
            json={"name": "绿萝", "water_interval_days": days},
        )
    ).json()["data"]


async def _water_notice_count(client: AsyncClient, fid: str) -> int:
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    return len(
        [
            n
            for n in notifs
            if n.get("type") == "plant_water_due" and n.get("family_id") == fid
        ]
    )


async def test_fires_when_water_due(client: AsyncClient) -> None:
    fid = await _create_family(client)
    plant = await _plant_with_water_cycle(client, fid, days=3)
    due = date.fromisoformat(plant["next_water_due"])

    async with async_session_maker() as session:
        await check_due_plants(session, today=due)

    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    water = [
        n for n in notifs if n.get("type") == "plant_water_due" and n["family_id"] == fid
    ]
    assert len(water) == 1
    assert "浇水" in water[0]["title"]
    assert "绿萝" in water[0]["title"]


async def test_idempotent_same_due_date(client: AsyncClient) -> None:
    fid = await _create_family(client)
    plant = await _plant_with_water_cycle(client, fid, days=3)
    due = date.fromisoformat(plant["next_water_due"])

    async with async_session_maker() as session:
        await check_due_plants(session, today=due)
    # A second pass on the same day must not re-notify (due date rolled forward).
    async with async_session_maker() as session:
        await check_due_plants(session, today=due)

    assert await _water_notice_count(client, fid) == 1


async def test_due_date_rolls_forward(client: AsyncClient) -> None:
    fid = await _create_family(client)
    plant = await _plant_with_water_cycle(client, fid, days=3)
    due = date.fromisoformat(plant["next_water_due"])

    async with async_session_maker() as session:
        await check_due_plants(session, today=due)

    got = await client.get(f"{BASE.format(fid=fid)}/plants/{plant['id']}")
    new_due = date.fromisoformat(got.json()["data"]["next_water_due"])
    assert new_due == due + timedelta(days=3)


async def test_not_due_does_not_fire(client: AsyncClient) -> None:
    fid = await _create_family(client)
    plant = await _plant_with_water_cycle(client, fid, days=3)
    due = date.fromisoformat(plant["next_water_due"])

    async with async_session_maker() as session:
        await check_due_plants(session, today=due - timedelta(days=1))

    assert await _water_notice_count(client, fid) == 0


async def test_plant_without_cycle_never_fires(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # No interval set → no reminder armed.
    await client.post(f"{BASE.format(fid=fid)}/plants", json={"name": "仙人掌"})
    async with async_session_maker() as session:
        await check_due_plants(session, today=date(2030, 1, 1))

    assert await _water_notice_count(client, fid) == 0
