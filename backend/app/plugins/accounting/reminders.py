"""Accounting month-end reminder.

On the last day of each month, at/after 21:00 Asia/Shanghai, nudge every family
that has the accounting plugin installed to review the month's balance. Fires at
most once per family per calendar month — idempotency piggybacks on the
notifications table (an existing `accounting_month_end` row dated within the
current local month means we've already sent), so no extra state table is
needed.

`check_month_end_accounting` is one pass and takes `now` as a parameter so tests
drive it deterministically. `run_accounting_monthly_loop` is the long-lived poll
loop started from the app lifespan when the feature is enabled.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from datetime import UTC, date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.config import settings
from app.core.database import async_session_maker
from app.models.notification import Notification
from app.models.plugin import InstalledPlugin
from app.services import notification as notification_service

logger = logging.getLogger(__name__)

# The reminder is anchored to China local time regardless of server timezone.
SHANGHAI = ZoneInfo("Asia/Shanghai")
NOTICE_HOUR = 21  # 9 PM local
NOTIFICATION_TYPE = "accounting_month_end"
ACCOUNTING_PLUGIN_ID = "accounting"


def _is_last_day_of_month(d: date) -> bool:
    return (d + timedelta(days=1)).month != d.month


async def _family_ids_with_accounting(session: AsyncSession) -> list[UUID]:
    stmt = (
        select(InstalledPlugin.family_id)
        .where(
            InstalledPlugin.plugin_id == ACCOUNTING_PLUGIN_ID,
            InstalledPlugin.enabled.is_(True),
        )
        .distinct()
    )
    return list((await session.execute(stmt)).scalars().all())


async def _already_notified_this_month(
    session: AsyncSession, family_id: UUID, since_utc: datetime
) -> bool:
    stmt = (
        select(func.count())
        .select_from(Notification)
        .where(
            Notification.family_id == family_id,
            Notification.type == NOTIFICATION_TYPE,
            Notification.created_at >= since_utc,
        )
    )
    return int((await session.execute(stmt)).scalar_one()) > 0


async def check_month_end_accounting(
    session: AsyncSession, *, now: datetime | None = None
) -> int:
    """One reminder pass. Returns how many families were notified.

    Only acts on the last day of the (local) month at/after 21:00; otherwise it's
    a no-op, so polling it hourly is safe.
    """
    now_local = (now or datetime.now(SHANGHAI)).astimezone(SHANGHAI)
    if not _is_last_day_of_month(now_local.date()) or now_local.hour < NOTICE_HOUR:
        return 0

    # Start of the current local month, as a UTC instant, for the dedupe query.
    month_start_utc = now_local.replace(
        day=1, hour=0, minute=0, second=0, microsecond=0
    ).astimezone(UTC)

    family_ids = await _family_ids_with_accounting(session)
    notified = 0
    for family_id in family_ids:
        if await _already_notified_this_month(session, family_id, month_start_utc):
            continue
        await notification_service.notify_family(
            session,
            family_id=family_id,
            notification_type=NOTIFICATION_TYPE,
            title="本月最后一天啦 💰",
            body="今天是本月的最后一天啦，看看还有多少结余吧 🧮",
            icon_emoji="💰",
            deeplink=f"wo://family/{family_id}/plugins/accounting",
        )
        notified += 1

    await session.commit()
    return notified


async def run_accounting_monthly_loop(stop: asyncio.Event) -> None:
    """Poll loop: run a check, then idle until the next tick or shutdown."""
    logger.info("accounting month-end loop started")
    while not stop.is_set():
        try:
            async with async_session_maker() as session:
                count = await check_month_end_accounting(session)
                if count:
                    logger.info("accounting month-end notices sent to %d family", count)
        except Exception:  # noqa: BLE001 — the loop must survive transient failures
            logger.exception("accounting month-end check failed")
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(
                stop.wait(), timeout=settings.accounting_monthly_notice_poll_seconds
            )
    logger.info("accounting month-end loop stopped")
