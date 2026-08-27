"""Due reminder loop for 宠物日常 care plans."""

import asyncio
import contextlib
import logging
from datetime import date

from sqlalchemy import exists
from sqlmodel import select

from app.core.config import settings
from app.core.database import async_session_maker
from app.models.pet import Pet
from app.models.plugin import InstalledPlugin
from app.plugins.pet.models import PetCarePlan
from app.services import notification as notification_service

logger = logging.getLogger(__name__)


async def check_due_pet_plans(session, *, today: date | None = None) -> int:
    today = today or date.today()
    installed = exists().where(
        InstalledPlugin.family_id == PetCarePlan.family_id,
        InstalledPlugin.plugin_id == "pet",
        InstalledPlugin.enabled.is_(True),
    )
    stmt = (
        select(PetCarePlan, Pet)
        .join(Pet, Pet.id == PetCarePlan.pet_id)
        .where(
            PetCarePlan.active.is_(True),
            PetCarePlan.next_due_date.is_not(None),
            PetCarePlan.next_due_date <= today,
            Pet.archived_at.is_(None),
            installed,
        )
    )
    rows = (await session.execute(stmt)).all()
    touched = 0
    for plan, pet in rows:
        if plan.last_notified_due_date == plan.next_due_date:
            continue
        overdue = (today - plan.next_due_date).days if plan.next_due_date else 0
        body = "今天到期，完成后会自动记录到健康时间线"
        if overdue > 0:
            body = f"已经逾期 {overdue} 天，完成后会自动记录到健康时间线"
        await notification_service.notify_family(
            session,
            family_id=plan.family_id,
            notification_type="pet_care_due",
            title=f"{pet.emoji or '🐾'} {pet.name} · {plan.name}",
            body=body,
            icon_emoji=pet.emoji or "🐾",
            deeplink=f"wo://family/{plan.family_id}/plugins/pet?pet={pet.id}",
        )
        plan.last_notified_due_date = plan.next_due_date
        session.add(plan)
        touched += 1
    await session.commit()
    return touched


async def run_pet_reminder_loop(stop: asyncio.Event) -> None:
    logger.info("pet reminder loop started")
    while not stop.is_set():
        try:
            async with async_session_maker() as session:
                count = await check_due_pet_plans(session)
                if count:
                    logger.info("pet reminder events for %d plan(s)", count)
        except Exception:  # noqa: BLE001
            logger.exception("pet reminder check failed")
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(stop.wait(), timeout=settings.pet_reminder_poll_seconds)
    logger.info("pet reminder loop stopped")


__all__ = ["check_due_pet_plans", "run_pet_reminder_loop"]
