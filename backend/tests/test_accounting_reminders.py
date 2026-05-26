"""Accounting month-end reminder: fires last day 21:00, once per month, only
for families that installed the accounting plugin."""

import uuid
from datetime import datetime

from httpx import AsyncClient

from app.core.database import async_session_maker
from app.plugins.accounting.reminders import SHANGHAI, check_month_end_accounting


def _name() -> str:
    return f"月末测试-{uuid.uuid4().hex[:8]}"


async def _family_with_accounting(client: AsyncClient) -> str:
    fid = (await client.post("/api/v1/families", json={"name": _name()})).json()["data"]["id"]
    resp = await client.post(
        f"/api/v1/families/{fid}/plugins", json={"plugin_id": "accounting"}
    )
    assert resp.status_code in (200, 201), resp.text
    return fid


async def _family_without_accounting(client: AsyncClient) -> str:
    return (await client.post("/api/v1/families", json={"name": _name()})).json()["data"]["id"]


def _month_end_notices(notifs: list[dict], fid: str) -> list[dict]:
    return [
        n
        for n in notifs
        if n.get("type") == "accounting_month_end" and n.get("family_id") == fid
    ]


# A real month-end at 21:00 Shanghai; 2026-02-28 is the last day of Feb.
LAST_DAY_9PM = datetime(2026, 2, 28, 21, 0, tzinfo=SHANGHAI)


async def test_fires_on_last_day_9pm_for_accounting_family(client: AsyncClient) -> None:
    fid = await _family_with_accounting(client)

    async with async_session_maker() as session:
        n = await check_month_end_accounting(session, now=LAST_DAY_9PM)
    assert n >= 1

    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    due = _month_end_notices(notifs, fid)
    assert len(due) == 1
    assert "最后一天" in due[0]["body"]
    assert "结余" in due[0]["body"]
    assert due[0]["icon_emoji"] == "💰"


async def test_idempotent_within_same_month(client: AsyncClient) -> None:
    fid = await _family_with_accounting(client)
    async with async_session_maker() as session:
        await check_month_end_accounting(session, now=LAST_DAY_9PM)
    # Second pass the same evening (e.g. the 22:00 tick) must not re-notify.
    async with async_session_maker() as session:
        await check_month_end_accounting(
            session, now=datetime(2026, 2, 28, 22, 0, tzinfo=SHANGHAI)
        )
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    assert len(_month_end_notices(notifs, fid)) == 1


async def test_skips_before_9pm(client: AsyncClient) -> None:
    fid = await _family_with_accounting(client)
    async with async_session_maker() as session:
        n = await check_month_end_accounting(
            session, now=datetime(2026, 2, 28, 20, 0, tzinfo=SHANGHAI)
        )
    assert n == 0
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    assert _month_end_notices(notifs, fid) == []


async def test_skips_when_not_last_day(client: AsyncClient) -> None:
    fid = await _family_with_accounting(client)
    async with async_session_maker() as session:
        n = await check_month_end_accounting(
            session, now=datetime(2026, 2, 27, 21, 0, tzinfo=SHANGHAI)
        )
    assert n == 0
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    assert _month_end_notices(notifs, fid) == []


async def test_skips_family_without_accounting(client: AsyncClient) -> None:
    fid = await _family_without_accounting(client)
    async with async_session_maker() as session:
        await check_month_end_accounting(session, now=LAST_DAY_9PM)
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    assert _month_end_notices(notifs, fid) == []
