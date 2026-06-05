"""Retirement automated monthly events + the poll loop.

Three idempotent event types, each guarded by a `retire_ledger` row keyed on
(family, kind, period[, account/debt]) so a given month is applied at most once
(the same dedupe-via-existing-rows trick the accounting reminder uses):

1. **Income credit** (req 4): on each account's `income_day`, add its
   `monthly_income` to the balance. Skipped for the account's creation month if
   the income_day had already passed when it was created (no retroactive back-pay).
2. **Debt payment** (req 3): on each active debt's `payment_day`, shrink the debt
   by `monthly_payment` (clamped to the remaining balance, retiring it at 0) and,
   when linked, deduct the same amount from a deposit account.
3. **Month-end expense settle** (req 8): deduct last month's accounting total from
   the earliest-created deposit account. Skipped for a family with no account
   created before this month (so a freshly-installed plugin doesn't claw back
   spend it never tracked).

`check_retirement` is one pass and takes `now` for deterministic tests;
`run_retirement_loop` is the long-lived poll loop started from the app lifespan
when the feature is enabled.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from datetime import UTC, date, datetime
from decimal import Decimal
from uuid import UUID
from zoneinfo import ZoneInfo

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.config import settings
from app.core.database import async_session_maker
from app.models.plugin import InstalledPlugin
from app.plugins.accounting.service import month_total
from app.plugins.retirement import service
from app.plugins.retirement.models import RetireAccount, RetireLedger
from app.services import notification as notification_service

logger = logging.getLogger(__name__)

SHANGHAI = ZoneInfo("Asia/Shanghai")
RETIREMENT_PLUGIN_ID = "retirement"
_ZERO = Decimal("0")
_DEEPLINK = "wo://family/{fid}/plugins/retirement"


def _period(d: date) -> str:
    return f"{d.year:04d}-{d.month:02d}"


def _local_date(dt: datetime) -> date:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(SHANGHAI).date()


async def _families_with_retirement(session: AsyncSession) -> list[UUID]:
    stmt = (
        select(InstalledPlugin.family_id)
        .where(
            InstalledPlugin.plugin_id == RETIREMENT_PLUGIN_ID,
            InstalledPlugin.enabled.is_(True),
        )
        .distinct()
    )
    return list((await session.execute(stmt)).scalars().all())


async def _ledger_exists(
    session: AsyncSession,
    family_id: UUID,
    kind: str,
    period: str,
    *,
    account_id: UUID | None = None,
    debt_id: UUID | None = None,
) -> bool:
    stmt = (
        select(func.count())
        .select_from(RetireLedger)
        .where(
            RetireLedger.family_id == family_id,
            RetireLedger.kind == kind,
            RetireLedger.period == period,
        )
    )
    if account_id is not None:
        stmt = stmt.where(RetireLedger.account_id == account_id)
    if debt_id is not None:
        stmt = stmt.where(RetireLedger.debt_id == debt_id)
    return int((await session.execute(stmt)).scalar_one()) > 0


async def _credit_incomes(
    session: AsyncSession,
    family_id: UUID,
    today: date,
    period: str,
    month_start: date,
) -> int:
    count = 0
    for acc in await service.get_accounts(session, family_id):
        if acc.monthly_income <= _ZERO or today.day < acc.income_day:
            continue
        # No creation-month back-pay if payday had already passed at creation.
        created = _local_date(acc.created_at)
        if created >= month_start and created.day > acc.income_day:
            continue
        if await _ledger_exists(session, family_id, "income", period, account_id=acc.id):
            continue
        acc.balance += acc.monthly_income
        session.add(acc)
        session.add(
            RetireLedger(
                family_id=family_id,
                kind="income",
                account_id=acc.id,
                amount=acc.monthly_income,
                period=period,
                note=f"{acc.name} 月收入入账",
            )
        )
        count += 1
    return count


async def _charge_debts(session: AsyncSession, family_id: UUID, today: date, period: str) -> int:
    count = 0
    for debt in await service.get_active_debts(session, family_id):
        if today.day < debt.payment_day:
            continue
        if await _ledger_exists(session, family_id, "debt_payment", period, debt_id=debt.id):
            continue
        amount = min(debt.monthly_payment, debt.balance)
        if amount <= _ZERO:
            continue
        debt.balance -= amount
        if debt.balance <= _ZERO:
            debt.balance = _ZERO
            debt.active = False
        if debt.from_account_id is not None:
            account = await session.get(RetireAccount, debt.from_account_id)
            if account is not None and account.family_id == family_id:
                account.balance -= amount
                session.add(account)
        session.add(debt)
        session.add(
            RetireLedger(
                family_id=family_id,
                kind="debt_payment",
                debt_id=debt.id,
                account_id=debt.from_account_id,
                amount=amount,
                period=period,
                note=f"{debt.name} 月供扣款",
            )
        )
        body = (
            "已经还清啦，撒花 🎉"
            if not debt.active
            else f"剩余 {service.format_amount(debt.balance)}"
        )
        await notification_service.notify_family(
            session,
            family_id=family_id,
            notification_type="retirement_debt_charged",
            title=f"「{debt.name}」已还款 {service.format_amount(amount)}",
            body=body,
            icon_emoji=debt.emoji or "🏠",
            deeplink=_DEEPLINK.format(fid=family_id),
        )
        count += 1
    return count


async def _settle_expenses(
    session: AsyncSession,
    family_id: UUID,
    today: date,
    period: str,
    month_start: date,
) -> int:
    if await _ledger_exists(session, family_id, "expense_settle", period):
        return 0
    accounts = await service.get_accounts(session, family_id)
    # Guard: skip families with no account predating this month.
    if not any(_local_date(a.created_at) < month_start for a in accounts):
        return 0

    py, pm = service.prev_month(today.year, today.month)
    amount = await month_total(session, family_id, year=py, month=pm)
    # accounts come back created_at-ascending, so this is the earliest deposit.
    deposit = next((a for a in accounts if a.kind == "deposit"), None)

    deducted = amount > _ZERO and deposit is not None
    if deducted:
        deposit.balance -= amount
        session.add(deposit)
        note = f"结算 {py:04d}-{pm:02d} 记账支出"
        account_id: UUID | None = deposit.id
    elif amount <= _ZERO:
        note = f"{py:04d}-{pm:02d} 无记账支出"
        account_id = None
    else:
        note = "无存款账户可扣"
        account_id = None

    session.add(
        RetireLedger(
            family_id=family_id,
            kind="expense_settle",
            account_id=account_id,
            amount=amount,
            period=period,
            note=note,
        )
    )
    if deducted:
        await notification_service.notify_family(
            session,
            family_id=family_id,
            notification_type="retirement_expense_settled",
            title=f"上月支出已结算 {service.format_amount(amount)}",
            body=f"已从「{deposit.name}」中扣除",
            icon_emoji="🧮",
            deeplink=_DEEPLINK.format(fid=family_id),
        )
    return 1


async def check_retirement(session: AsyncSession, *, now: datetime | None = None) -> int:
    """One pass. Returns how many automated events fired. Commits once so a
    debt payment and its balance changes can't half-apply."""
    now_local = (now or datetime.now(SHANGHAI)).astimezone(SHANGHAI)
    today = now_local.date()
    period = _period(today)
    month_start = date(today.year, today.month, 1)

    touched = 0
    for family_id in await _families_with_retirement(session):
        touched += await _credit_incomes(session, family_id, today, period, month_start)
        touched += await _charge_debts(session, family_id, today, period)
        touched += await _settle_expenses(session, family_id, today, period, month_start)

    await session.commit()
    return touched


async def run_retirement_loop(stop: asyncio.Event) -> None:
    """Poll loop: run a check, then idle until the next tick or shutdown."""
    logger.info("retirement loop started")
    while not stop.is_set():
        try:
            async with async_session_maker() as session:
                count = await check_retirement(session)
                if count:
                    logger.info("retirement: %d automated event(s)", count)
        except Exception:  # noqa: BLE001 — the loop must survive transient failures
            logger.exception("retirement check failed")
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(stop.wait(), timeout=settings.retirement_reminder_poll_seconds)
    logger.info("retirement loop stopped")
