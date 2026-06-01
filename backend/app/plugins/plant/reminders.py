"""Plant watering / fertilizing due reminders.

A periodic pass over plants with an armed care cycle:

- When `next_water_due` is on/before today and we haven't reminded for that date,
  notify the family ("该浇水了"), mark it, and roll the due date forward one
  watering interval. Fertilizing works the same with its own fields.

`check_due_plants` is one pass and takes `today` for deterministic tests.
`run_plant_reminder_loop` is the long-lived poll loop started from the app
lifespan when the feature is enabled. Mirrors subscription/reminders.py.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from datetime import date

from sqlmodel import select

from app.core.config import settings
from app.core.database import async_session_maker
from app.plugins.plant.models import Plant
from app.services import notification as notification_service

logger = logging.getLogger(__name__)


def _advance(due: date, interval_days: int) -> date:
    """Roll a due date forward by the interval, past today if it was overdue, so
    a missed window doesn't fire every poll."""
    today = date.today()
    nxt = date.fromordinal(due.toordinal() + interval_days)
    while nxt <= today:
        nxt = date.fromordinal(nxt.toordinal() + interval_days)
    return nxt


async def check_due_plants(session, *, today: date | None = None) -> int:
    """One pass. Returns how many plants had a reminder event.

    Stages all notifications + date roll-forwards and commits once.
    """
    today = today or date.today()
    rows = list((await session.execute(select(Plant))).scalars().all())

    touched = 0
    for plant in rows:
        fired = False

        # Watering.
        if (
            plant.water_interval_days
            and plant.next_water_due is not None
            and plant.next_water_due <= today
            and plant.last_notified_water_due != plant.next_water_due
        ):
            await notification_service.notify_family(
                session,
                family_id=plant.family_id,
                notification_type="plant_water_due",
                title=f"🌿 该给「{plant.name}」浇水了",
                body="别忘了今天的浇水哦",
                icon_emoji=plant.emoji or "🌿",
                deeplink=f"wo://family/{plant.family_id}/plugins/plant",
            )
            plant.last_notified_water_due = plant.next_water_due
            plant.next_water_due = _advance(
                plant.next_water_due, plant.water_interval_days
            )
            fired = True

        # Fertilizing.
        if (
            plant.fert_interval_days
            and plant.next_fert_due is not None
            and plant.next_fert_due <= today
            and plant.last_notified_fert_due != plant.next_fert_due
        ):
            await notification_service.notify_family(
                session,
                family_id=plant.family_id,
                notification_type="plant_fert_due",
                title=f"🌿 该给「{plant.name}」施肥了",
                body="到了施肥的日子啦",
                icon_emoji=plant.emoji or "🌿",
                deeplink=f"wo://family/{plant.family_id}/plugins/plant",
            )
            plant.last_notified_fert_due = plant.next_fert_due
            plant.next_fert_due = _advance(
                plant.next_fert_due, plant.fert_interval_days
            )
            fired = True

        if fired:
            session.add(plant)
            touched += 1

    await session.commit()
    return touched


async def run_plant_reminder_loop(stop: asyncio.Event) -> None:
    """Poll loop: run a check, then idle until the next tick or shutdown."""
    logger.info("plant reminder loop started")
    while not stop.is_set():
        try:
            async with async_session_maker() as session:
                count = await check_due_plants(session)
                if count:
                    logger.info("plant reminder events for %d plant(s)", count)
        except Exception:  # noqa: BLE001 — the loop must survive transient failures
            logger.exception("plant reminder check failed")
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(
                stop.wait(), timeout=settings.plant_reminder_poll_seconds
            )
    logger.info("plant reminder loop stopped")


__all__ = ["check_due_plants", "run_plant_reminder_loop"]
