"""Retirement reminder-loop tests — income credit, debt payment, and the
month-start accounting-expense settle, plus the idempotency / guard behaviour.

Rows are inserted directly (with controlled `created_at`) and `now` is injected,
so the assertions don't depend on the real wall-clock month/day.
"""

import uuid
from datetime import UTC, datetime
from decimal import Decimal
from zoneinfo import ZoneInfo

from httpx import AsyncClient
from sqlmodel import select

from app.core.database import async_session_maker
from app.models.plugin import InstalledPlugin
from app.plugins.accounting.models import Transaction
from app.plugins.retirement.models import RetireAccount, RetireDebt, RetireLedger
from app.plugins.retirement.reminders import check_retirement

SHANGHAI = ZoneInfo("Asia/Shanghai")
# A created_at safely before any test month, so the income/settle guards never
# treat a row as "created this month".
OLD = datetime(2025, 1, 1, tzinfo=UTC)


async def _create_family(client: AsyncClient) -> uuid.UUID:
    resp = await client.post("/api/v1/families", json={"name": f"测试-{uuid.uuid4().hex[:6]}"})
    return uuid.UUID(resp.json()["data"]["id"])


async def _install(family_id: uuid.UUID, plugin_id: str) -> None:
    async with async_session_maker() as session:
        session.add(
            InstalledPlugin(family_id=family_id, plugin_id=plugin_id, col=0, row=0, cw=2, ch=2)
        )
        await session.commit()


async def _add_account(family_id: uuid.UUID, **fields) -> uuid.UUID:
    defaults = dict(
        name="工资卡",
        kind="deposit",
        balance=Decimal("0"),
        monthly_income=Decimal("0"),
        income_day=1,
        created_at=OLD,
    )
    defaults.update(fields)
    row = RetireAccount(family_id=family_id, **defaults)
    async with async_session_maker() as session:
        session.add(row)
        await session.commit()
        await session.refresh(row)
        return row.id


async def _add_debt(family_id: uuid.UUID, **fields) -> uuid.UUID:
    defaults = dict(
        name="房贷",
        kind="mortgage",
        balance=Decimal("10000"),
        monthly_payment=Decimal("3000"),
        payment_day=5,
        created_at=OLD,
    )
    defaults.update(fields)
    row = RetireDebt(family_id=family_id, **defaults)
    async with async_session_maker() as session:
        session.add(row)
        await session.commit()
        await session.refresh(row)
        return row.id


async def _add_txn(family_id: uuid.UUID, amount: str, when: datetime) -> None:
    async with async_session_maker() as session:
        session.add(
            Transaction(
                family_id=family_id,
                amount=Decimal(amount),
                category="dining",
                created_at=when,
            )
        )
        await session.commit()


async def _run(now: datetime) -> int:
    async with async_session_maker() as session:
        return await check_retirement(session, now=now)


async def _account(account_id: uuid.UUID) -> RetireAccount:
    async with async_session_maker() as session:
        return await session.get(RetireAccount, account_id)


async def _debt(debt_id: uuid.UUID) -> RetireDebt:
    async with async_session_maker() as session:
        return await session.get(RetireDebt, debt_id)


async def _ledger(family_id: uuid.UUID, kind: str | None = None) -> list[RetireLedger]:
    async with async_session_maker() as session:
        stmt = select(RetireLedger).where(RetireLedger.family_id == family_id)
        if kind is not None:
            stmt = stmt.where(RetireLedger.kind == kind)
        return list((await session.execute(stmt)).scalars().all())


# ---- Income credit (req 4) -------------------------------------------------


async def test_income_credited_on_income_day_and_idempotent(
    client: AsyncClient,
) -> None:
    fid = await _create_family(client)
    await _install(fid, "retirement")
    due = await _add_account(
        fid, balance=Decimal("1000"), monthly_income=Decimal("5000"), income_day=10
    )
    not_due = await _add_account(
        fid, balance=Decimal("2000"), monthly_income=Decimal("7000"), income_day=20
    )

    now = datetime(2026, 6, 10, 9, tzinfo=SHANGHAI)
    await _run(now)

    assert (await _account(due)).balance == Decimal("6000")  # credited
    assert (await _account(not_due)).balance == Decimal("2000")  # day 10 < 20
    income_rows = await _ledger(fid, "income")
    assert len(income_rows) == 1
    assert income_rows[0].account_id == due

    # Second pass on the same day is a no-op (idempotent via the ledger).
    await _run(now)
    assert (await _account(due)).balance == Decimal("6000")
    assert len(await _ledger(fid, "income")) == 1


# ---- Debt payment (req 3) --------------------------------------------------


async def test_debt_payment_reduces_debt_and_account(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _install(fid, "retirement")
    acc = await _add_account(fid, balance=Decimal("50000"), monthly_income=Decimal("0"))
    debt = await _add_debt(
        fid,
        balance=Decimal("10000"),
        monthly_payment=Decimal("3000"),
        payment_day=5,
        from_account_id=acc,
    )

    now = datetime(2026, 6, 5, 9, tzinfo=SHANGHAI)
    await _run(now)

    assert (await _debt(debt)).balance == Decimal("7000")
    assert (await _account(acc)).balance == Decimal("47000")
    pay_rows = await _ledger(fid, "debt_payment")
    assert len(pay_rows) == 1 and pay_rows[0].amount == Decimal("3000")

    # Idempotent on a re-run.
    await _run(now)
    assert (await _debt(debt)).balance == Decimal("7000")
    assert (await _account(acc)).balance == Decimal("47000")


async def test_debt_clamps_and_retires_at_zero(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _install(fid, "retirement")
    acc = await _add_account(fid, balance=Decimal("5000"), monthly_income=Decimal("0"))
    debt = await _add_debt(
        fid,
        balance=Decimal("2000"),
        monthly_payment=Decimal("3000"),
        payment_day=5,
        from_account_id=acc,
    )

    await _run(datetime(2026, 6, 5, 9, tzinfo=SHANGHAI))

    row = await _debt(debt)
    assert row.balance == Decimal("0")
    assert row.active is False  # paid off → deactivated
    # Only the remaining ¥2000 was drawn (clamped), not the full ¥3000.
    assert (await _account(acc)).balance == Decimal("3000")


async def test_debt_not_charged_before_payment_day(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _install(fid, "retirement")
    debt = await _add_debt(fid, balance=Decimal("10000"), payment_day=15)
    await _run(datetime(2026, 6, 5, 9, tzinfo=SHANGHAI))
    assert (await _debt(debt)).balance == Decimal("10000")
    assert await _ledger(fid, "debt_payment") == []


# ---- Month-start expense settle (req 8) ------------------------------------


async def test_expense_settle_deducts_last_month_accounting(
    client: AsyncClient,
) -> None:
    fid = await _create_family(client)
    await _install(fid, "retirement")
    await _install(fid, "accounting")
    acc = await _add_account(fid, balance=Decimal("100000"), monthly_income=Decimal("0"))
    # Two May expenses totalling ¥3000.
    await _add_txn(fid, "2000", datetime(2026, 5, 10, tzinfo=UTC))
    await _add_txn(fid, "1000", datetime(2026, 5, 20, tzinfo=UTC))

    await _run(datetime(2026, 6, 1, 9, tzinfo=SHANGHAI))

    assert (await _account(acc)).balance == Decimal("97000")
    rows = await _ledger(fid, "expense_settle")
    assert len(rows) == 1
    assert rows[0].amount == Decimal("3000")
    assert rows[0].period == "2026-06"

    # Idempotent: re-running the same month doesn't double-deduct.
    await _run(datetime(2026, 6, 1, 9, tzinfo=SHANGHAI))
    assert (await _account(acc)).balance == Decimal("97000")
    assert len(await _ledger(fid, "expense_settle")) == 1


async def test_expense_settle_skips_brand_new_family(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _install(fid, "retirement")
    # Account created *this* month (== month_start, not before) → guard skips.
    acc = await _add_account(
        fid, balance=Decimal("100000"), created_at=datetime(2026, 6, 1, tzinfo=UTC)
    )
    await _add_txn(fid, "3000", datetime(2026, 5, 10, tzinfo=UTC))

    await _run(datetime(2026, 6, 1, 9, tzinfo=SHANGHAI))

    assert (await _account(acc)).balance == Decimal("100000")  # untouched
    assert await _ledger(fid, "expense_settle") == []


async def test_expense_settle_records_zero_when_no_expenses(
    client: AsyncClient,
) -> None:
    fid = await _create_family(client)
    await _install(fid, "retirement")
    acc = await _add_account(fid, balance=Decimal("100000"))

    await _run(datetime(2026, 6, 1, 9, tzinfo=SHANGHAI))

    assert (await _account(acc)).balance == Decimal("100000")
    rows = await _ledger(fid, "expense_settle")
    assert len(rows) == 1 and rows[0].amount == Decimal("0")


async def test_expense_settle_without_deposit_records_marker(
    client: AsyncClient,
) -> None:
    fid = await _create_family(client)
    await _install(fid, "retirement")
    # Only a fund account (no deposit to draw from), created before this month.
    fund = await _add_account(fid, kind="fund", balance=Decimal("80000"))
    await _add_txn(fid, "3000", datetime(2026, 5, 10, tzinfo=UTC))

    await _run(datetime(2026, 6, 1, 9, tzinfo=SHANGHAI))

    assert (await _account(fund)).balance == Decimal("80000")  # fund never touched
    rows = await _ledger(fid, "expense_settle")
    assert len(rows) == 1
    assert rows[0].amount == Decimal("3000")
    assert rows[0].account_id is None  # nothing deducted, just a marker
