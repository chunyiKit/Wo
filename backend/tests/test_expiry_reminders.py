"""Expiry (到期管家) reminder-loop tests — pre-expiry window, overdue notice,
idempotency, paused skip, and re-arm on date edit.

`check_due_expiries` scans every family's items (it's a global daily pass) and
the test DB is shared across tests, so assertions target the specific row's
dedup columns rather than the global `touched` count. The one place a count is
checked is idempotency: a *second* identical pass must fire nothing (0), which
holds regardless of how many other rows exist.
"""

import uuid
from datetime import date, timedelta

from httpx import AsyncClient

from app.core.database import async_session_maker
from app.plugins.expiry.models import ExpiryItem
from app.plugins.expiry.reminders import check_due_expiries

BASE = "/api/v1/families/{fid}/plugins/expiry/items"


async def _create_family(client: AsyncClient) -> str:
    resp = await client.post("/api/v1/families", json={"name": f"测试-{uuid.uuid4().hex[:6]}"})
    return resp.json()["data"]["id"]


async def _create_item(client: AsyncClient, fid: str, **overrides) -> dict:
    body = {
        "name": "护照",
        "kind": "passport",
        "expire_on": (date.today() + timedelta(days=40)).isoformat(),
        "notify_enabled": True,
        "notify_days_before": 30,
        "active": True,
    }
    body.update(overrides)
    resp = await client.post(BASE.format(fid=fid), json=body)
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]


async def _get(item_id: str) -> ExpiryItem:
    async with async_session_maker() as session:
        return await session.get(ExpiryItem, uuid.UUID(item_id))


async def _check(today: date) -> int:
    async with async_session_maker() as session:
        return await check_due_expiries(session, today=today)


# ---- pre-expiry window -----------------------------------------------------


async def test_pre_expiry_reminder_marks_dedup(client: AsyncClient) -> None:
    fid = await _create_family(client)
    today = date.today()
    due = today + timedelta(days=10)
    item = await _create_item(client, fid, expire_on=due.isoformat(), notify_days_before=30)

    await _check(today)
    row = await _get(item["id"])
    assert row.last_pre_notified_on == due
    assert row.last_expired_notified_on is None


async def test_pre_expiry_idempotent(client: AsyncClient) -> None:
    fid = await _create_family(client)
    today = date.today()
    due = today + timedelta(days=10)
    item = await _create_item(client, fid, expire_on=due.isoformat())
    await _check(today)
    assert (await _get(item["id"])).last_pre_notified_on == due
    # A second identical pass fires nothing more (globally idempotent).
    assert await _check(today) == 0


async def test_outside_window_no_reminder(client: AsyncClient) -> None:
    fid = await _create_family(client)
    today = date.today()
    due = today + timedelta(days=100)
    item = await _create_item(client, fid, expire_on=due.isoformat(), notify_days_before=30)
    await _check(today)
    assert (await _get(item["id"])).last_pre_notified_on is None


async def test_notify_disabled_skips_pre_expiry(client: AsyncClient) -> None:
    fid = await _create_family(client)
    today = date.today()
    due = today + timedelta(days=5)
    item = await _create_item(client, fid, expire_on=due.isoformat(), notify_enabled=False)
    await _check(today)
    assert (await _get(item["id"])).last_pre_notified_on is None


# ---- overdue ---------------------------------------------------------------


async def test_overdue_notice_marks_dedup(client: AsyncClient) -> None:
    fid = await _create_family(client)
    today = date.today()
    due = today - timedelta(days=2)
    item = await _create_item(client, fid, expire_on=due.isoformat())
    await _check(today)
    assert (await _get(item["id"])).last_expired_notified_on == due


async def test_overdue_idempotent(client: AsyncClient) -> None:
    fid = await _create_family(client)
    today = date.today()
    due = today - timedelta(days=2)
    item = await _create_item(client, fid, expire_on=due.isoformat())
    await _check(today)
    assert (await _get(item["id"])).last_expired_notified_on == due
    assert await _check(today) == 0


async def test_overdue_fires_even_when_notify_disabled(client: AsyncClient) -> None:
    """The overdue notice is a safety net and ignores notify_enabled (which only
    gates the *pre*-expiry reminder)."""
    fid = await _create_family(client)
    today = date.today()
    due = today - timedelta(days=1)
    item = await _create_item(client, fid, expire_on=due.isoformat(), notify_enabled=False)
    await _check(today)
    assert (await _get(item["id"])).last_expired_notified_on == due


# ---- paused + re-arm -------------------------------------------------------


async def test_paused_item_skipped(client: AsyncClient) -> None:
    fid = await _create_family(client)
    today = date.today()
    item = await _create_item(
        client,
        fid,
        expire_on=(today - timedelta(days=1)).isoformat(),
        active=False,
    )
    await _check(today)
    row = await _get(item["id"])
    assert row.last_pre_notified_on is None
    assert row.last_expired_notified_on is None


async def test_editing_date_rearms_reminder(client: AsyncClient) -> None:
    fid = await _create_family(client)
    today = date.today()
    due = today + timedelta(days=10)
    item = await _create_item(client, fid, expire_on=due.isoformat())
    await _check(today)
    assert (await _get(item["id"])).last_pre_notified_on == due

    # Renew → push the expiry date out; dedup guards reset so it can fire again.
    new_due = today + timedelta(days=20)
    resp = await client.put(
        f"{BASE.format(fid=fid)}/{item['id']}",
        json={"expire_on": new_due.isoformat()},
    )
    assert resp.status_code == 200
    assert (await _get(item["id"])).last_pre_notified_on is None

    await _check(today)
    assert (await _get(item["id"])).last_pre_notified_on == new_due
