"""Calendar (家历) due-date reminders.

A daily background check: for each calendar item with reminders enabled, when
today is within `notify_days_before` days of its next occurrence, emit a family
notification — exactly once per occurrence (idempotent via
`last_notified_occurrence`). Notifications flow through the normal pipeline
(`notifications` table → push outbox), showing in the message center and, when
push is enabled, ringing the phone.

`check_due_calendar_items` is one pass and takes `today` as a parameter so tests
drive it deterministically. `run_calendar_reminder_loop` is the long-lived poll
loop started from the app lifespan when the feature is enabled.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from datetime import date

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.config import settings
from app.core.database import async_session_maker
from app.plugins.calendar.models import CalendarItem
from app.plugins.calendar.service import next_occurrence
from app.services import notification as notification_service

logger = logging.getLogger(__name__)


def _format_time(start_minute: int | None) -> str:
    if start_minute is None:
        return ""
    return f" {start_minute // 60:02d}:{start_minute % 60:02d}"


def _build_message(item: CalendarItem, delta: int) -> tuple[str, str]:
    """Title + body for the reminder. `delta` is days until the occurrence."""
    when = _format_time(item.start_minute)
    if delta <= 0:
        return (f"今天：{item.title}", f"别忘了这件事{when} 📅".strip())
    if delta == 1:
        return (f"明天：{item.title}", f"提前准备一下{when} 📅".strip())
    return (f"「{item.title}」还有 {delta} 天", "记得安排好时间 📅")


async def check_due_calendar_items(
    session: AsyncSession, *, today: date | None = None
) -> int:
    """One reminder pass. Returns how many items were notified.

    Stages notifications + flips `last_notified_occurrence`, then commits once so
    the two are atomic (no double-notify if a later pass races the same row).
    """
    today = today or date.today()
    stmt = select(CalendarItem).where(
        CalendarItem.notify_enabled.is_(True),
        CalendarItem.done.is_(False),
    )
    rows = list((await session.execute(stmt)).scalars().all())

    notified = 0
    for row in rows:
        if row.event_date is None:
            continue
        occ = next_occurrence(row.event_date, row.repeat, today)
        delta = (occ - today).days
        # Not yet within the reminder window (or somehow past) → skip.
        if delta < 0 or delta > row.notify_days_before:
            continue
        # Already reminded for this occurrence → skip.
        if row.last_notified_occurrence == occ:
            continue

        title, body = _build_message(row, delta)
        await notification_service.notify_family(
            session,
            family_id=row.family_id,
            notification_type="calendar_due",
            title=title,
            body=body,
            icon_emoji=row.emoji or "📅",
            deeplink=f"wo://family/{row.family_id}/plugins/calendar",
        )
        row.last_notified_occurrence = occ
        session.add(row)
        notified += 1

    await session.commit()
    return notified


async def run_calendar_reminder_loop(stop: asyncio.Event) -> None:
    """Poll loop: run a check, then idle until the next tick or shutdown."""
    logger.info("calendar reminder loop started")
    while not stop.is_set():
        try:
            async with async_session_maker() as session:
                count = await check_due_calendar_items(session)
                if count:
                    logger.info("calendar reminders emitted for %d item(s)", count)
        except Exception:  # noqa: BLE001 — the loop must survive transient failures
            logger.exception("calendar reminder check failed")
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(
                stop.wait(), timeout=settings.calendar_reminder_poll_seconds
            )
    logger.info("calendar reminder loop stopped")
