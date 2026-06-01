"""Stock weekly inventory reminder: fires Saturday 20:00, once per Saturday,
only for families that installed the stock plugin."""

import uuid
from datetime import datetime

from httpx import AsyncClient

from app.core.database import async_session_maker
from app.plugins.stock.reminders import SHANGHAI, check_weekly_stock_inventory


def _name() -> str:
    return f"囤货测试-{uuid.uuid4().hex[:8]}"


async def _family_with_stock(client: AsyncClient) -> str:
    fid = (await client.post("/api/v1/families", json={"name": _name()})).json()["data"]["id"]
    resp = await client.post(
        f"/api/v1/families/{fid}/plugins", json={"plugin_id": "stock"}
    )
    assert resp.status_code in (200, 201), resp.text
    return fid


async def _family_without_stock(client: AsyncClient) -> str:
    return (await client.post("/api/v1/families", json={"name": _name()})).json()["data"]["id"]


def _weekly_notices(notifs: list[dict], fid: str) -> list[dict]:
    return [
        n
        for n in notifs
        if n.get("type") == "stock_weekly_inventory" and n.get("family_id") == fid
    ]


# 2026-05-23 is a Saturday; 20:00 Shanghai is the reminder moment. The date is
# deliberately in the past relative to the test clock: notify_family stamps
# created_at with the real wall clock, and the dedupe window is "start of the
# simulated local day", so that window must precede real-now for the idempotency
# check to see the just-created row (mirrors test_accounting_reminders).
SATURDAY_8PM = datetime(2026, 5, 23, 20, 0, tzinfo=SHANGHAI)


async def test_fires_on_saturday_8pm_for_stock_family(client: AsyncClient) -> None:
    fid = await _family_with_stock(client)

    async with async_session_maker() as session:
        n = await check_weekly_stock_inventory(session, now=SATURDAY_8PM)
    assert n >= 1

    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    due = _weekly_notices(notifs, fid)
    assert len(due) == 1
    assert "盘点" in due[0]["title"]
    assert "采买清单" in due[0]["body"]
    assert due[0]["icon_emoji"] == "🛒"


async def test_idempotent_within_same_saturday(client: AsyncClient) -> None:
    fid = await _family_with_stock(client)
    async with async_session_maker() as session:
        await check_weekly_stock_inventory(session, now=SATURDAY_8PM)
    # A later tick the same evening (e.g. 21:00) must not re-notify.
    async with async_session_maker() as session:
        await check_weekly_stock_inventory(
            session, now=datetime(2026, 5, 23, 21, 0, tzinfo=SHANGHAI)
        )
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    assert len(_weekly_notices(notifs, fid)) == 1


async def test_skips_before_8pm(client: AsyncClient) -> None:
    fid = await _family_with_stock(client)
    async with async_session_maker() as session:
        n = await check_weekly_stock_inventory(
            session, now=datetime(2026, 5, 23, 19, 0, tzinfo=SHANGHAI)
        )
    assert n == 0
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    assert _weekly_notices(notifs, fid) == []


async def test_skips_when_not_saturday(client: AsyncClient) -> None:
    fid = await _family_with_stock(client)
    # 2026-05-22 is a Friday.
    async with async_session_maker() as session:
        n = await check_weekly_stock_inventory(
            session, now=datetime(2026, 5, 22, 20, 0, tzinfo=SHANGHAI)
        )
    assert n == 0
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    assert _weekly_notices(notifs, fid) == []


async def test_skips_family_without_stock(client: AsyncClient) -> None:
    fid = await _family_without_stock(client)
    async with async_session_maker() as session:
        await check_weekly_stock_inventory(session, now=SATURDAY_8PM)
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    assert _weekly_notices(notifs, fid) == []
