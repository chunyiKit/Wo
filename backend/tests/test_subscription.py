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
    resp = await client.post("/api/v1/families", json={"name": f"测试-{uuid.uuid4().hex[:6]}"})
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
            (
                await session.execute(
                    select(Transaction).where(Transaction.family_id == uuid.UUID(family_id))
                )
            )
            .scalars()
            .all()
        )
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
    assert txns[0].exclude_from_budget is False
    assert str(txns[0].amount) == "30.00"
    assert "Netflix" in (txns[0].note or "")

    rolled = await _get_sub(sub["id"])
    assert rolled.next_due == advance_due(today, "monthly")
    assert rolled.last_charged_due == today


async def test_due_yearly_advances_one_year(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _install_accounting(fid)
    today = date.today()
    sub = await _create_sub(client, fid, cycle="yearly", next_due=today.isoformat())
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
    sub = await _create_sub(client, fid, next_due=due.isoformat(), notify_days_before=3)
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


async def test_default_accounting_options_and_partial_update(client: AsyncClient) -> None:
    fid = await _create_family(client)
    sub = await _create_sub(client, fid)
    assert sub["accounting_category"] == "subscription"
    assert sub["exclude_from_budget"] is False
    updated = await client.put(
        BASE.format(fid=fid) + f"/{sub['id']}",
        json={"accounting_category": "utilities", "exclude_from_budget": True},
    )
    assert updated.status_code == 200, updated.text
    paused = await client.put(BASE.format(fid=fid) + f"/{sub['id']}", json={"active": False})
    assert paused.json()["data"]["accounting_category"] == "utilities"
    assert paused.json()["data"]["exclude_from_budget"] is True
    listed = (await client.get(BASE.format(fid=fid))).json()["data"]
    assert listed[0]["accounting_category"] == "utilities"
    assert listed[0]["exclude_from_budget"] is True


async def test_custom_category_budget_and_future_charges(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _install_accounting(fid)
    accounting = f"/api/v1/families/{fid}/plugins/accounting"
    category = (await client.post(accounting + "/categories", json={"label": "房租"})).json()[
        "data"
    ]
    await client.put(accounting + "/budget", json={"monthly_amount": 1000})
    sub = await _create_sub(
        client,
        fid,
        accounting_category=category["code"],
        exclude_from_budget=True,
    )
    async with async_session_maker() as session:
        await check_due_subscriptions(session, today=date.today())
    txns = await _family_txns(fid)
    assert len(txns) == 1
    original_id = txns[0].id
    assert txns[0].category == category["code"]
    assert txns[0].exclude_from_budget is True
    summary = (await client.get(accounting + "/summary")).json()["data"]
    assert float(summary["month_total"]) == 30
    assert float(summary["excluded_total"]) == 30
    assert float(summary["remaining"]) == 1000
    notifications = (await client.get("/api/v1/notifications")).json()["data"]
    charged = [
        n for n in notifications if n["type"] == "subscription_charged" and n["family_id"] == fid
    ]
    assert charged and "不计入月预算" in charged[0]["body"]
    assert "订阅分类" not in charged[0]["body"]

    updated = await client.put(
        BASE.format(fid=fid) + f"/{sub['id']}",
        json={"accounting_category": "utilities", "exclude_from_budget": False},
    )
    assert updated.status_code == 200
    next_due = date.fromisoformat(updated.json()["data"]["next_due"])
    async with async_session_maker() as session:
        await check_due_subscriptions(session, today=next_due)
    async with async_session_maker() as session:
        await check_due_subscriptions(session, today=next_due)
    txns = await _family_txns(fid)
    assert len(txns) == 2
    original = next(t for t in txns if t.id == original_id)
    following = next(t for t in txns if t.id != original_id)
    assert original.category == category["code"] and original.exclude_from_budget is True
    assert following.category == "utilities" and following.exclude_from_budget is False
    summary = (await client.get(accounting + "/summary")).json()["data"]
    assert float(summary["month_total"]) == 60
    assert float(summary["budgeted_total"]) == 30
    assert float(summary["remaining"]) == 970


async def test_accounting_settings_reject_invalid_or_foreign_category(client: AsyncClient) -> None:
    fid, other = await _create_family(client), await _create_family(client)
    category = (
        await client.post(
            f"/api/v1/families/{other}/plugins/accounting/categories",
            json={"label": "房租"},
        )
    ).json()["data"]
    sub = await _create_sub(client, fid)
    for value in ("bogus", category["code"], "", None):
        created = await client.post(
            BASE.format(fid=fid),
            json={
                "name": "房租",
                "amount": 100,
                "next_due": date.today().isoformat(),
                "accounting_category": value,
            },
        )
        assert created.status_code == 422, created.text
        updated = await client.put(
            BASE.format(fid=fid) + f"/{sub['id']}",
            json={"accounting_category": value},
        )
        assert updated.status_code == 422, updated.text
    updated = await client.put(
        BASE.format(fid=fid) + f"/{sub['id']}",
        json={"exclude_from_budget": None},
    )
    assert updated.status_code == 422
