"""Subscription (订阅管家) tests — CRUD, due-loop charge + accounting record,
cycle advance, accounting-absent fallback, pre-due reminder, paused skip."""

import uuid
from datetime import date, timedelta

from httpx import AsyncClient
from sqlmodel import select

from app.core.database import async_session_maker
from app.models.plugin import InstalledPlugin
from app.plugins.accounting.models import Transaction
from app.plugins.subscription.models import Subscription
from app.plugins.subscription.reminders import check_due_subscriptions
from app.plugins.subscription.service import advance_due

BASE = "/api/v1/families/{fid}/plugins/subscription/subscriptions"


async def _create_family(client: AsyncClient) -> str:
    resp = await client.post(
        "/api/v1/families", json={"name": f"测试-{uuid.uuid4().hex[:6]}"}
    )
    return resp.json()["data"]["id"]


async def _install_accounting(family_id: str) -> None:
    """Insert an installed_plugins row for accounting (the plugins.id row is
    seeded at lifespan, so the FK resolves)."""
    async with async_session_maker() as session:
        session.add(
            InstalledPlugin(
                family_id=uuid.UUID(family_id),
                plugin_id="accounting",
                col=0,
                row=0,
                cw=2,
                ch=2,
            )
        )
        await session.commit()


async def _create_sub(client: AsyncClient, fid: str, **overrides) -> dict:
    body = {
        "name": "Netflix",
        "amount": "30",
        "cycle": "monthly",
        "next_due": date.today().isoformat(),
        "auto_record": True,
        "notify_enabled": True,
        "notify_days_before": 3,
        "active": True,
    }
    body.update(overrides)
    resp = await client.post(BASE.format(fid=fid), json=body)
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]


async def _family_txns(family_id: str) -> list[Transaction]:
    async with async_session_maker() as session:
        rows = (
            await session.execute(
                select(Transaction).where(
                    Transaction.family_id == uuid.UUID(family_id)
                )
            )
        ).scalars().all()
        return list(rows)


async def _get_sub(sub_id: str) -> Subscription:
    async with async_session_maker() as session:
        return await session.get(Subscription, uuid.UUID(sub_id))


# ---- date math -------------------------------------------------------------


def test_advance_due_monthly_and_clamp() -> None:
    assert advance_due(date(2026, 1, 15), "monthly") == date(2026, 2, 15)
    # Jan 31 → Feb has no 31st → clamp to 28 (2026 not a leap year).
    assert advance_due(date(2026, 1, 31), "monthly") == date(2026, 2, 28)
    # December rolls the year.
    assert advance_due(date(2026, 12, 10), "monthly") == date(2027, 1, 10)


def test_advance_due_yearly() -> None:
    assert advance_due(date(2026, 6, 1), "yearly") == date(2027, 6, 1)


# ---- CRUD ------------------------------------------------------------------


async def test_create_and_list(client: AsyncClient) -> None:
    fid = await _create_family(client)
    created = await _create_sub(client, fid, name="iCloud", amount="6.80")
    assert created["name"] == "iCloud"
    assert created["cycle"] == "monthly"
    assert created["days_until"] == 0
    listed = (await client.get(BASE.format(fid=fid))).json()["data"]
    assert len(listed) == 1


async def test_validation(client: AsyncClient) -> None:
    fid = await _create_family(client)
    bad_name = await client.post(
        BASE.format(fid=fid),
        json={"name": "  ", "amount": "10", "next_due": date.today().isoformat()},
    )
    assert bad_name.status_code == 400
    bad_amount = await client.post(
        BASE.format(fid=fid),
        json={"name": "x", "amount": "0", "next_due": date.today().isoformat()},
    )
    assert bad_amount.status_code == 400


# ---- due loop + accounting -------------------------------------------------


async def test_due_records_to_accounting_and_advances(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _install_accounting(fid)
    today = date.today()
    sub = await _create_sub(client, fid, amount="30", next_due=today.isoformat())

    async with async_session_maker() as session:
        await check_due_subscriptions(session, today=today)

    txns = await _family_txns(fid)
    assert len(txns) == 1
    assert txns[0].category == "subscription"
    assert str(txns[0].amount) == "30.00"
    assert "Netflix" in (txns[0].note or "")

    rolled = await _get_sub(sub["id"])
    assert rolled.next_due == advance_due(today, "monthly")
    assert rolled.last_charged_due == today


async def test_due_yearly_advances_one_year(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _install_accounting(fid)
    today = date.today()
    sub = await _create_sub(
        client, fid, cycle="yearly", next_due=today.isoformat()
    )
    async with async_session_maker() as session:
        await check_due_subscriptions(session, today=today)
    rolled = await _get_sub(sub["id"])
    assert rolled.next_due == advance_due(today, "yearly")


async def test_due_without_accounting_advances_but_no_txn(
    client: AsyncClient,
) -> None:
    """No accounting plugin installed → no transaction created, but the due date
    still rolls forward so the subscription stays on schedule."""
    fid = await _create_family(client)  # note: accounting NOT installed
    today = date.today()
    sub = await _create_sub(client, fid, next_due=today.isoformat())
    async with async_session_maker() as session:
        await check_due_subscriptions(session, today=today)
    assert await _family_txns(fid) == []
    rolled = await _get_sub(sub["id"])
    assert rolled.next_due == advance_due(today, "monthly")


async def test_auto_record_off_skips_txn(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _install_accounting(fid)
    today = date.today()
    await _create_sub(client, fid, auto_record=False, next_due=today.isoformat())
    async with async_session_maker() as session:
        await check_due_subscriptions(session, today=today)
    assert await _family_txns(fid) == []


async def test_paused_not_processed(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _install_accounting(fid)
    today = date.today()
    sub = await _create_sub(client, fid, active=False, next_due=today.isoformat())
    async with async_session_maker() as session:
        await check_due_subscriptions(session, today=today)
    assert await _family_txns(fid) == []
    rolled = await _get_sub(sub["id"])
    assert rolled.next_due == today  # unchanged


async def test_predue_reminder_marks_and_no_advance(client: AsyncClient) -> None:
    fid = await _create_family(client)
    today = date.today()
    due = today + timedelta(days=2)
    sub = await _create_sub(
        client, fid, next_due=due.isoformat(), notify_days_before=3
    )
    async with async_session_maker() as session:
        await check_due_subscriptions(session, today=today)
    rolled = await _get_sub(sub["id"])
    # Not due yet → date unchanged, but the pre-due reminder is marked sent.
    assert rolled.next_due == due
    assert rolled.last_notified_due == due


async def test_due_charge_is_idempotent_per_due_date(client: AsyncClient) -> None:
    """If a due date was already charged but its date somehow didn't advance
    (a stuck row, or a duplicate/overlapping pass), the next pass must NOT charge
    it again. `last_charged_due == next_due` is the idempotency guard."""
    fid = await _create_family(client)
    await _install_accounting(fid)
    today = date.today()
    sub = await _create_sub(client, fid, amount="30", next_due=today.isoformat())

    # Simulate "already charged this exact due date, but the date is still here".
    async with async_session_maker() as session:
        row = await session.get(Subscription, uuid.UUID(sub["id"]))
        row.last_charged_due = row.next_due
        session.add(row)
        await session.commit()

    async with async_session_maker() as session:
        await check_due_subscriptions(session, today=today)

    # No second charge, and the (stuck) date is left untouched — not advanced
    # again on top of an already-charged period.
    assert await _family_txns(fid) == []
    rolled = await _get_sub(sub["id"])
    assert rolled.next_due == today


async def test_due_then_repoll_charges_once_and_advances(client: AsyncClient) -> None:
    """Happy path stays exactly-once: a due monthly sub is charged + advanced on
    the first pass, and a second pass the same day does nothing more."""
    fid = await _create_family(client)
    await _install_accounting(fid)
    today = date.today()
    sub = await _create_sub(client, fid, amount="12", next_due=today.isoformat())

    async with async_session_maker() as session:
        await check_due_subscriptions(session, today=today)
    async with async_session_maker() as session:
        await check_due_subscriptions(session, today=today)

    assert len(await _family_txns(fid)) == 1
    rolled = await _get_sub(sub["id"])
    assert rolled.next_due == advance_due(today, "monthly")
    assert rolled.last_charged_due == today
