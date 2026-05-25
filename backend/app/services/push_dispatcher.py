"""Transactional-outbox dispatcher for push notifications.

The notification service stages a `push_outbox` row in the same transaction as
the notification it mirrors, so the intent to push is durable and atomic with
the triggering event. This module drains those rows: for each it loads the
recipient's device tokens and hands them to a `PushSender`, marking the row
`sent` (delivered, or nothing to deliver to) or `failed` after
`push_max_attempts`.

Two entry points:
- `dispatch_pending` — one drain pass. Pure of scheduling concerns and takes the
  sender as an argument, so tests drive it directly with a fake sender.
- `run_push_dispatcher` — the long-lived poll loop, started from the app
  lifespan when `settings.push_enabled` is true.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from datetime import UTC, datetime

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.config import settings
from app.core.database import async_session_maker
from app.models.notification import Notification
from app.models.push_outbox import STATUS_FAILED, STATUS_PENDING, STATUS_SENT, PushOutbox
from app.services import device_token as device_service
from app.services.push import JPushClient, PushMessage, PushSender

logger = logging.getLogger(__name__)


def _extras_for(notif: Notification) -> dict[str, str]:
    """Data payload the app reads on tap (deep-link target, dedup key, type)."""
    extras = {"notification_id": str(notif.id), "type": notif.type}
    if notif.deeplink:
        extras["deeplink"] = notif.deeplink
    return extras


async def dispatch_pending(
    session: AsyncSession,
    sender: PushSender,
    *,
    batch_size: int | None = None,
    max_attempts: int | None = None,
) -> int:
    """Drain one batch of pending outbox rows. Returns how many were processed."""
    batch_size = batch_size if batch_size is not None else settings.push_batch_size
    max_attempts = max_attempts if max_attempts is not None else settings.push_max_attempts

    # FOR UPDATE SKIP LOCKED makes this a safe work queue: the prod service runs
    # multiple uvicorn workers, each with its own dispatcher loop. Locking the
    # claimed rows (and skipping rows another worker already holds) ensures each
    # pending row is delivered by exactly one worker — no duplicate pushes. Locks
    # release on the commit at the end of this pass.
    stmt = (
        select(PushOutbox)
        .where(PushOutbox.status == STATUS_PENDING)
        .order_by(PushOutbox.created_at)
        .limit(batch_size)
        .with_for_update(skip_locked=True)
    )
    rows = list((await session.execute(stmt)).scalars().all())

    for row in rows:
        notif = await session.get(Notification, row.notification_id)
        # Notification gone (e.g. user deleted) or recipient has no device: nothing
        # to deliver — settle the row so the dispatcher won't keep reprocessing it.
        if notif is None:
            _mark_sent(row)
            session.add(row)
            continue
        tokens = await device_service.tokens_for_user(session, notif.user_id)
        if not tokens:
            _mark_sent(row)
            session.add(row)
            continue

        message = PushMessage(
            registration_ids=tokens,
            title=notif.title,
            body=notif.body,
            extras=_extras_for(notif),
        )
        try:
            await sender(message)
        except Exception as exc:  # noqa: BLE001 — provider/network errors trigger retry
            row.attempts += 1
            row.last_error = str(exc)[:500]
            if row.attempts >= max_attempts:
                row.status = STATUS_FAILED
            logger.warning("push send failed (attempt %d/%d): %s", row.attempts, max_attempts, exc)
        else:
            _mark_sent(row)
        session.add(row)

    await session.commit()
    return len(rows)


def _mark_sent(row: PushOutbox) -> None:
    row.status = STATUS_SENT
    row.sent_at = datetime.now(UTC)


async def run_push_dispatcher(stop: asyncio.Event) -> None:
    """Poll loop: drain the outbox, then idle until the next tick or shutdown."""
    client = JPushClient.from_settings(settings)
    logger.info("push dispatcher started (jpush_configured=%s)", client.configured)
    while not stop.is_set():
        processed = 0
        try:
            async with async_session_maker() as session:
                processed = await dispatch_pending(session, client.send_push)
        except Exception:  # noqa: BLE001 — the loop must survive transient failures
            logger.exception("push dispatch pass failed")
        # Keep draining while there's a full-ish backlog; otherwise wait the poll
        # interval (waking early if shutdown is requested).
        if processed == 0:
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(stop.wait(), timeout=settings.push_poll_interval_seconds)
    logger.info("push dispatcher stopped")
