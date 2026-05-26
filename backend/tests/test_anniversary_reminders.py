"""Anniversary due-date reminder check: fires within window, once per occurrence."""

import uuid
from datetime import date

from httpx import AsyncClient

from app.core.database import async_session_maker
from app.plugins.anniversary.reminders import check_due_anniversaries


def _name() -> str:
    return f"提醒测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    resp = await client.post("/api/v1/families", json={"name": _name()})
    return resp.json()["data"]["id"]


async def _create_anniv(
    client: AsyncClient,
    fid: str,
    *,
    event_date: str,
    notify_enabled: bool,
    notify_days_before: int,
) -> dict:
    resp = await client.post(
        f"/api/v1/families/{fid}/plugins/anniversary/dates",
        json={
            "name": _name(),
            "event_date": event_date,
            "emoji": "🎂",
            "is_lunar": False,
            "notify_enabled": notify_enabled,
            "notify_days_before": notify_days_before,
        },
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]


def _due_notifs(notifs: list[dict], fid: str) -> list[dict]:
    return [
        n
        for n in notifs
        if n.get("type") == "anniversary_due" and n.get("family_id") == fid
    ]


async def test_create_persists_notify_fields(client: AsyncClient) -> None:
    fid = await _create_family(client)
    data = await _create_anniv(
        client, fid, event_date="2000-06-01", notify_enabled=True, notify_days_before=3
    )
    assert data["notify_enabled"] is True
    assert data["notify_days_before"] == 3


async def test_reminder_fires_within_window_and_is_idempotent(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # Event recurs on Jun 1; with today = May 30, occurrence is 2 days out.
    await _create_anniv(
        client, fid, event_date="2000-06-01", notify_enabled=True, notify_days_before=3
    )
    today = date(2026, 5, 30)

    before = (await client.get("/api/v1/notifications")).json()["data"]
    assert _due_notifs(before, fid) == []

    async with async_session_maker() as session:
        n1 = await check_due_anniversaries(session, today=today)
    assert n1 >= 1

    after = (await client.get("/api/v1/notifications")).json()["data"]
    due = _due_notifs(after, fid)
    assert len(due) == 1, "owner should get exactly one anniversary_due notification"
    assert "还有 2 天" in due[0]["title"]
    assert due[0]["icon_emoji"] == "🎂"

    # Second pass for the same occurrence must NOT re-notify (idempotent).
    async with async_session_maker() as session:
        await check_due_anniversaries(session, today=today)
    after2 = (await client.get("/api/v1/notifications")).json()["data"]
    assert len(_due_notifs(after2, fid)) == 1


async def test_reminder_skips_outside_window(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # 2 days out but window is only 1 day → should not fire.
    await _create_anniv(
        client, fid, event_date="2000-06-01", notify_enabled=True, notify_days_before=1
    )
    async with async_session_maker() as session:
        await check_due_anniversaries(session, today=date(2026, 5, 30))
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    assert _due_notifs(notifs, fid) == []


async def test_reminder_skips_when_disabled(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _create_anniv(
        client, fid, event_date="2000-06-01", notify_enabled=False, notify_days_before=3
    )
    async with async_session_maker() as session:
        await check_due_anniversaries(session, today=date(2026, 5, 30))
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    assert _due_notifs(notifs, fid) == []


async def test_reminder_fires_on_the_day_when_zero_days_before(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _create_anniv(
        client, fid, event_date="2000-06-01", notify_enabled=True, notify_days_before=0
    )
    # The day before: 0-day window → nothing yet.
    async with async_session_maker() as session:
        await check_due_anniversaries(session, today=date(2026, 5, 31))
    assert _due_notifs((await client.get("/api/v1/notifications")).json()["data"], fid) == []
    # The day itself → fires with the "今天是" copy.
    async with async_session_maker() as session:
        await check_due_anniversaries(session, today=date(2026, 6, 1))
    due = _due_notifs((await client.get("/api/v1/notifications")).json()["data"], fid)
    assert len(due) == 1
    assert "今天是" in due[0]["title"]
