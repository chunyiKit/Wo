"""Stock (囤货铺) weekly inventory reminder.

Every Saturday at/after 20:00 Asia/Shanghai, nudge every family that has the
stock plugin installed to do a weekly inventory count together. Fires at most
once per family per Saturday — idempotency piggybacks on the notifications
table (an existing `stock_weekly_inventory` row dated on/after today's local
midnight means we've already sent this Saturday), so no extra state table is
needed.

`check_weekly_stock_inventory` is one pass and takes `now` as a parameter so
tests drive it deterministically. `run_stock_weekly_loop` is the long-lived
poll loop started from the app lifespan when the feature is enabled.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from datetime import UTC, datetime
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

# Anchored to China local time regardless of server timezone.
SHANGHAI = ZoneInfo("Asia/Shanghai")
NOTICE_WEEKDAY = 5  # Saturday (Mon=0 … Sun=6)
NOTICE_HOUR = 20  # 8 PM local
NOTIFICATION_TYPE = "stock_weekly_inventory"
STOCK_PLUGIN_ID = "stock"

REMINDER_TITLE = "周末囤货盘点 🛒"
REMINDER_BODY = "和家人一起清点下家里的囤货吧～看看还剩多少、缺了啥，该补的加进采买清单 📝"


async def _family_ids_with_stock(session: AsyncSession) -> list[UUID]:
    stmt = (
        select(InstalledPlugin.family_id)
        .where(
            InstalledPlugin.plugin_id == STOCK_PLUGIN_ID,
            InstalledPlugin.enabled.is_(True),
        )
        .distinct()
    )
    return list((await session.execute(stmt)).scalars().all())


async def _already_notified_today(
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


async def check_weekly_stock_inventory(
    session: AsyncSession, *, now: datetime | None = None
) -> int:
    """One reminder pass. Returns how many families were notified.

    Only acts on Saturday (local) at/after 20:00; otherwise it's a no-op, so
    polling it hourly is safe.
    """
    now_local = (now or datetime.now(SHANGHAI)).astimezone(SHANGHAI)
    if now_local.weekday() != NOTICE_WEEKDAY or now_local.hour < NOTICE_HOUR:
        return 0

    # Start of the current local day, as a UTC instant, for the dedupe query.
    day_start_utc = now_local.replace(
        hour=0, minute=0, second=0, microsecond=0
    ).astimezone(UTC)

    family_ids = await _family_ids_with_stock(session)
    notified = 0
    for family_id in family_ids:
        if await _already_notified_today(session, family_id, day_start_utc):
            continue
        await notification_service.notify_family(
            session,
            family_id=family_id,
            notification_type=NOTIFICATION_TYPE,
            title=REMINDER_TITLE,
            body=REMINDER_BODY,
            icon_emoji="🛒",
            deeplink=f"wo://family/{family_id}/plugins/stock",
        )
        notified += 1

    await session.commit()
    return notified


async def run_stock_weekly_loop(stop: asyncio.Event) -> None:
    """Poll loop: run a check, then idle until the next tick or shutdown."""
    logger.info("stock weekly inventory loop started")
    while not stop.is_set():
        try:
            async with async_session_maker() as session:
                count = await check_weekly_stock_inventory(session)
                if count:
                    logger.info(
                        "stock weekly inventory notices sent to %d family", count
                    )
        except Exception:  # noqa: BLE001 — the loop must survive transient failures
            logger.exception("stock weekly inventory check failed")
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(
                stop.wait(), timeout=settings.stock_weekly_notice_poll_seconds
            )
    logger.info("stock weekly inventory loop stopped")
