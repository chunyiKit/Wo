"""Expiry (到期管家) due reminders.

A daily background pass over active items, with two idempotent stages:

1. Pre-expiry reminder: within `notify_days_before` days of `expire_on`, emit a
   family notification once per expiry date (idempotent via
   `last_pre_notified_on`).
2. Overdue notice: once `expire_on` has passed, emit a one-off "已过期" notice
   (idempotent via `last_expired_notified_on`).

Unlike subscription, the date is never auto-advanced — the user edits the new
expiry date after renewing, which resets both dedup guards so the item re-arms.

`check_due_expiries` is one pass and takes `today` for deterministic tests.
`run_expiry_reminder_loop` is the long-lived poll loop started from the app
lifespan when the feature is enabled. Mirrors subscription/reminders.py.
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
from app.plugins.expiry.models import ExpiryItem

logger = logging.getLogger(__name__)


def _deeplink(family_id) -> str:
    return f"wo://family/{family_id}/plugins/expiry"


async def check_due_expiries(session: AsyncSession, *, today: date | None = None) -> int:
    """One pass. Returns how many items had a notification event.

    Stages every notification + dedup write and commits once.
    """
    # Imported lazily so this module stays importable without the notification
    # service being initialized at import time (mirrors the other reminders).
    from app.services import notification as notification_service

    today = today or date.today()
    stmt = select(ExpiryItem).where(ExpiryItem.active.is_(True))
    rows = list((await session.execute(stmt)).scalars().all())

    touched = 0
    for item in rows:
        delta = (item.expire_on - today).days

        # 1) Overdue → one-off "已过期" notice.
        if delta < 0:
            if item.last_expired_notified_on != item.expire_on:
                await notification_service.notify_family(
                    session,
                    family_id=item.family_id,
                    notification_type="expiry_expired",
                    title=f"「{item.name}」已过期",
                    body=f"已过期 {-delta} 天，记得尽快续期 📄",
                    icon_emoji=item.emoji or "📄",
                    deeplink=_deeplink(item.family_id),
                )
                item.last_expired_notified_on = item.expire_on
                session.add(item)
                touched += 1
            continue

        # 2) Pre-expiry reminder window.
        if (
            item.notify_enabled
            and delta <= item.notify_days_before
            and item.last_pre_notified_on != item.expire_on
        ):
            when = "今天" if delta == 0 else f"{delta} 天后"
            await notification_service.notify_family(
                session,
                family_id=item.family_id,
                notification_type="expiry_due",
                title=f"「{item.name}」{when}到期",
                body="记得提前安排续期 📄",
                icon_emoji=item.emoji or "📄",
                deeplink=_deeplink(item.family_id),
            )
            item.last_pre_notified_on = item.expire_on
            session.add(item)
            touched += 1

    await session.commit()
    return touched


async def run_expiry_reminder_loop(stop: asyncio.Event) -> None:
    """Poll loop: run a check, then idle until the next tick or shutdown."""
    logger.info("expiry reminder loop started")
    while not stop.is_set():
        try:
            async with async_session_maker() as session:
                count = await check_due_expiries(session)
                if count:
                    logger.info("expiry events for %d item(s)", count)
        except Exception:  # noqa: BLE001 — the loop must survive transient failures
            logger.exception("expiry reminder check failed")
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(stop.wait(), timeout=settings.expiry_reminder_poll_seconds)
    logger.info("expiry reminder loop stopped")
