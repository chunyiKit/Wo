"""Anniversary due-date reminders.

A daily background check: for each anniversary with reminders enabled, when today
is within `notify_days_before` days of its next occurrence (solar or lunar), emit
a family notification — exactly once per occurrence (idempotent via
`last_notified_event_date`). Those notifications flow through the normal pipeline
(`notifications` table → push outbox), so they show in the in-app message center
and, when push is enabled, ring the phone.

`check_due_anniversaries` is one pass and takes `today` as a parameter so tests
drive it deterministically. `run_anniversary_reminder_loop` is the long-lived
poll loop started from the app lifespan when the feature is enabled.
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
from app.plugins.anniversary.models import Anniversary
from app.plugins.anniversary.service import next_occurrence
from app.services import notification as notification_service

logger = logging.getLogger(__name__)


def _build_message(name: str, delta: int) -> tuple[str, str]:
    """Title + body for the reminder. `delta` is days until the occurrence."""
    if delta <= 0:
        return (f"今天是「{name}」", "别忘了这个特别的日子 🎉")
    return (f"「{name}」还有 {delta} 天", "记得提前准备哦 🎀")


async def check_due_anniversaries(
    session: AsyncSession, *, today: date | None = None
) -> int:
    """One reminder pass. Returns how many anniversaries were notified.

    Stages notifications + flips `last_notified_event_date`, then commits once so
    the two are atomic (no double-notify if a later pass races the same row).
    """
    today = today or date.today()
    stmt = select(Anniversary).where(Anniversary.notify_enabled.is_(True))
    rows = list((await session.execute(stmt)).scalars().all())

    notified = 0
    for row in rows:
        occ = next_occurrence(row.event_date, today, is_lunar=row.is_lunar)
        delta = (occ - today).days
        # Not yet within the reminder window (or somehow past) → skip.
        if delta < 0 or delta > row.notify_days_before:
            continue
        # Already reminded for this occurrence → skip (next year's occ differs).
        if row.last_notified_event_date == occ:
            continue

        title, body = _build_message(row.name, delta)
        await notification_service.notify_family(
            session,
            family_id=row.family_id,
            notification_type="anniversary_due",
            title=title,
            body=body,
            icon_emoji=row.emoji,
            deeplink=f"wo://family/{row.family_id}/plugins/anniversary",
        )
        row.last_notified_event_date = occ
        session.add(row)
        notified += 1

    await session.commit()
    return notified


async def run_anniversary_reminder_loop(stop: asyncio.Event) -> None:
    """Poll loop: run a check, then idle until the next tick or shutdown."""
    logger.info("anniversary reminder loop started")
    while not stop.is_set():
        try:
            async with async_session_maker() as session:
                count = await check_due_anniversaries(session)
                if count:
                    logger.info("anniversary reminders emitted for %d date(s)", count)
        except Exception:  # noqa: BLE001 — the loop must survive transient failures
            logger.exception("anniversary reminder check failed")
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(
                stop.wait(), timeout=settings.anniversary_reminder_poll_seconds
            )
    logger.info("anniversary reminder loop stopped")
