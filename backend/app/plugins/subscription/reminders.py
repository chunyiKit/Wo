"""Subscription due reminders + auto-record into accounting.

A daily background pass over active subscriptions:

1. Pre-due reminder: within `notify_days_before` days of `next_due`, emit a
   family notification once per due date (idempotent via `last_notified_due`).
2. On/after the due date: optionally auto-record the charge as a `subscription`
   transaction (only when `auto_record` and the family actually has the
   accounting plugin installed), notify that it was charged, then roll
   `next_due` forward one cycle so the next period re-arms.

`check_due_subscriptions` is one pass and takes `today` for deterministic tests.
`run_subscription_reminder_loop` is the long-lived poll loop started from the
app lifespan when the feature is enabled.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from datetime import date

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.config import settings
from app.core.database import async_session_maker
from app.models.plugin import InstalledPlugin
from app.plugins.accounting.models import Transaction
from app.plugins.subscription.models import Subscription
from app.plugins.subscription.service import advance_due, format_amount
from app.services import notification as notification_service

logger = logging.getLogger(__name__)

# The accounting category an auto-recorded charge lands in (must be in
# accounting's ALLOWED_CATEGORIES).
_ACCOUNTING_CATEGORY = "subscription"


async def _accounting_installed(session: AsyncSession, family_id) -> bool:
    stmt = (
        select(func.count())
        .select_from(InstalledPlugin)
        .where(
            InstalledPlugin.family_id == family_id,
            InstalledPlugin.plugin_id == "accounting",
        )
    )
    return int((await session.execute(stmt)).scalar_one()) > 0


async def _record_to_accounting(session: AsyncSession, sub: Subscription) -> None:
    """Stage a subscription-category transaction for this charge (not committed —
    the caller's commit makes it atomic with the date roll-forward)."""
    session.add(
        Transaction(
            family_id=sub.family_id,
            amount=sub.amount,
            category=_ACCOUNTING_CATEGORY,
            note=f"{sub.name} 订阅扣费",
            created_by=sub.created_by,
        )
    )


async def check_due_subscriptions(
    session: AsyncSession, *, today: date | None = None
) -> int:
    """One pass. Returns how many subscriptions had a notification/charge event.

    Stages everything (notifications, transactions, date roll-forward) and
    commits once so a charge and its date advance can't half-apply.
    """
    today = today or date.today()
    stmt = select(Subscription).where(Subscription.active.is_(True))
    rows = list((await session.execute(stmt)).scalars().all())

    touched = 0
    for sub in rows:
        delta = (sub.next_due - today).days

        # 2) Due today or overdue → charge + roll forward, exactly once per due
        # date. `last_charged_due` is the idempotency key: if we already
        # processed this exact due date (a duplicate/overlapping pass, or a
        # prior pass that charged but whose date advance didn't stick), skip so
        # we never double-record the same charge.
        if delta <= 0:
            if sub.last_charged_due == sub.next_due:
                continue
            recorded = False
            if sub.auto_record and await _accounting_installed(session, sub.family_id):
                await _record_to_accounting(session, sub)
                recorded = True
            amount = format_amount(sub.amount)
            if recorded:
                title = f"「{sub.name}」已扣费 {amount}"
                body = "已自动记入「记账」的订阅分类 💳"
            else:
                title = f"「{sub.name}」到期 {amount}"
                body = "记得续费哦 💳"
            await notification_service.notify_family(
                session,
                family_id=sub.family_id,
                notification_type="subscription_charged",
                title=title,
                body=body,
                icon_emoji=sub.emoji or "💳",
                deeplink=f"wo://family/{sub.family_id}/plugins/subscription",
            )
            sub.last_charged_due = sub.next_due
            sub.next_due = advance_due(sub.next_due, sub.cycle)
            sub.last_notified_due = None  # re-arm the pre-due reminder for next cycle
            session.add(sub)
            touched += 1
            continue

        # 1) Pre-due reminder window.
        if (
            sub.notify_enabled
            and delta <= sub.notify_days_before
            and sub.last_notified_due != sub.next_due
        ):
            amount = format_amount(sub.amount)
            await notification_service.notify_family(
                session,
                family_id=sub.family_id,
                notification_type="subscription_due",
                title=f"「{sub.name}」{delta} 天后扣费 {amount}",
                body="提前留意一下账户余额 💳",
                icon_emoji=sub.emoji or "💳",
                deeplink=f"wo://family/{sub.family_id}/plugins/subscription",
            )
            sub.last_notified_due = sub.next_due
            session.add(sub)
            touched += 1

    await session.commit()
    return touched


async def run_subscription_reminder_loop(stop: asyncio.Event) -> None:
    """Poll loop: run a check, then idle until the next tick or shutdown."""
    logger.info("subscription reminder loop started")
    while not stop.is_set():
        try:
            async with async_session_maker() as session:
                count = await check_due_subscriptions(session)
                if count:
                    logger.info("subscription events for %d item(s)", count)
        except Exception:  # noqa: BLE001 — the loop must survive transient failures
            logger.exception("subscription reminder check failed")
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(
                stop.wait(), timeout=settings.subscription_reminder_poll_seconds
            )
    logger.info("subscription reminder loop stopped")
