"""Home trend: Beijing day boundaries, fixed windows, and live previews."""

from datetime import UTC, date, datetime, time, timedelta
from decimal import Decimal
from uuid import UUID
from zoneinfo import ZoneInfo

import pytest
from httpx import AsyncClient

from app.core.database import async_session_maker
from app.plugins.accounting.models import Transaction
from app.plugins.accounting.service import recent_daily_expenses


async def _family(client: AsyncClient) -> UUID:
    response = await client.post("/api/v1/families", json={"name": "七日趋势测试"})
    assert response.status_code == 201, response.text
    return UUID(response.json()["data"]["id"])


@pytest.mark.parametrize("today", [date(2026, 1, 1), date(2024, 3, 1)])
async def test_beijing_window_and_family_isolation(client: AsyncClient, today: date) -> None:
    fid = await _family(client)
    other = await _family(client)
    zone = ZoneInfo("Asia/Shanghai")
    midnight = datetime.combine(today, time.min, zone).astimezone(UTC)
    start = midnight - timedelta(days=6)
    end = midnight + timedelta(days=1)
    async with async_session_maker() as session:
        for timestamp, amount, excluded, family in [
            (start - timedelta(microseconds=1), "99", False, fid),
            (start, "1.10", False, fid),
            (start + timedelta(days=1), "2.20", False, fid),
            (midnight - timedelta(microseconds=1), "3.30", False, fid),
            (midnight, "2.40", False, fid),
            (midnight + timedelta(minutes=1), "2.00", True, fid),
            (end, "99", False, fid),
            (midnight, "99", False, other),
        ]:
            session.add(
                Transaction(
                    family_id=family,
                    amount=Decimal(amount),
                    category="dining",
                    created_at=timestamp,
                    exclude_from_budget=excluded,
                )
            )
        await session.commit()
        # UTC is still the previous calendar date at Beijing 00:02.
        trend = await recent_daily_expenses(session, fid, now=midnight + timedelta(minutes=2))
    assert [p.date for p in trend.points] == [today - timedelta(days=i) for i in range(6, -1, -1)]
    assert [p.value for p in trend.points] == list(
        map(
            Decimal,
            ["1.10", "2.20", "0", "0", "0", "3.30", "4.40"],
        )
    )


@pytest.mark.parametrize("cw,ch", [(2, 1), (2, 2), (4, 2)])
async def test_preview_tracks_crud_for_every_card_size(
    client: AsyncClient,
    cw: int,
    ch: int,
) -> None:
    fid = await _family(client)
    installed = await client.post(
        f"/api/v1/families/{fid}/plugins",
        json={"plugin_id": "accounting", "layout": {"col": 0, "row": 0, "cw": cw, "ch": ch}},
    )
    assert installed.status_code == 201, installed.text
    switched = await client.post(f"/api/v1/families/{fid}/switch")
    assert switched.status_code == 200
    empty = installed.json()["data"]["preview"]["background_trend"]
    assert len(empty["points"]) == 7
    assert all(Decimal(p["value"]) == 0 for p in empty["points"])

    async def total() -> Decimal:
        response = await client.get("/api/v1/me/bootstrap")
        previews = response.json()["data"]["installed_plugins"]
        trend = next(p for p in previews if p["plugin_id"] == "accounting")["preview"][
            "background_trend"
        ]
        assert trend["label"] == "近7天每日支出"
        assert trend["unit"] == "元"
        assert len(trend["points"]) == 7
        return sum((Decimal(p["value"]) for p in trend["points"]), Decimal(0))

    route = f"/api/v1/families/{fid}/plugins/accounting/transactions"
    added = await client.post(route, json={"amount": "12.34", "category": "dining"})
    assert added.status_code == 201, added.text
    tid = added.json()["data"]["id"]
    assert await total() == Decimal("12.34")
    updated = await client.put(f"{route}/{tid}", json={"amount": "56.78"})
    assert updated.status_code == 200
    assert await total() == Decimal("56.78")
    deleted = await client.delete(f"{route}/{tid}")
    assert deleted.status_code == 200
    assert await total() == 0
