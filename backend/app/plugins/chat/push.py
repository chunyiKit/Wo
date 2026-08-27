"""Dedicated push outbox for chat messages.

Chat pushes should wake/open the chat page, but should not create rows in the
general in-app notification center. This module mirrors the existing push
dispatcher pattern with a chat-specific table.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.config import settings
from app.core.database import async_session_maker
from app.models.membership import Membership
from app.plugins.chat.models import (
    KIND_IMAGE,
    PUSH_FAILED,
    PUSH_PENDING,
    PUSH_SENT,
    ChatMessage,
    ChatPushOutbox,
)
from app.services import device_token as device_service
from app.services.notification_prefs import push_allowed
from app.services.push import JPushClient, PushMessage, PushSender

logger = logging.getLogger(__name__)


async def _recipient_ids(
    session: AsyncSession,
    *,
    family_id: UUID,
    excluding_user_id: UUID,
) -> list[UUID]:
    stmt = select(Membership.user_id).where(
        Membership.family_id == family_id,
        Membership.user_id != excluding_user_id,
        Membership.status == "active",
    )
    return list((await session.execute(stmt)).scalars().all())


async def stage_chat_pushes(session: AsyncSession, message: ChatMessage) -> None:
    """Stage per-recipient chat push intents in the caller's transaction."""
    if not settings.push_enabled or message.sender_id is None:
        return
    recipients = await _recipient_ids(
        session,
        family_id=message.family_id,
        excluding_user_id=message.sender_id,
    )
    for uid in recipients:
        if push_allowed(await _prefs_for(session, uid), "chat_message"):
            session.add(ChatPushOutbox(message_id=message.id, user_id=uid))


async def _prefs_for(session: AsyncSession, user_id: UUID) -> dict | None:
    from app.models.user import User

    row = await session.get(User, user_id)
    return row.notification_prefs if row is not None else None


def _extras_for(message: ChatMessage) -> dict[str, str]:
    deeplink = f"wo://family/{message.family_id}/plugins/chat"
    return {
        "type": "chat_message",
        "family_id": str(message.family_id),
        "message_id": str(message.id),
        "deeplink": deeplink,
    }


def _body_for(message: ChatMessage) -> str:
    if message.kind == KIND_IMAGE:
        return message.body or "发来一张图片"
    return (message.body or "发来一条消息")[:120]


async def dispatch_pending_chat(
    session: AsyncSession,
    sender: PushSender,
    *,
    batch_size: int | None = None,
    max_attempts: int | None = None,
) -> int:
    batch_size = batch_size if batch_size is not None else settings.push_batch_size
    max_attempts = max_attempts if max_attempts is not None else settings.push_max_attempts

    stmt = (
        select(ChatPushOutbox)
        .where(ChatPushOutbox.status == PUSH_PENDING)
        .order_by(ChatPushOutbox.created_at)
        .limit(batch_size)
        .with_for_update(skip_locked=True)
    )
    rows = list((await session.execute(stmt)).scalars().all())

    for row in rows:
        message = await session.get(ChatMessage, row.message_id)
        if message is None:
            _mark_sent(row)
            session.add(row)
            continue
        tokens = await device_service.tokens_for_user(session, row.user_id)
        if not tokens:
            _mark_sent(row)
            session.add(row)
            continue
        try:
            await sender(
                PushMessage(
                    registration_ids=tokens,
                    title=f"{message.sender_name} 发来消息",
                    body=_body_for(message),
                    extras=_extras_for(message),
                )
            )
        except Exception as exc:  # noqa: BLE001
            row.attempts += 1
            row.last_error = str(exc)[:500]
            if row.attempts >= max_attempts:
                row.status = PUSH_FAILED
            logger.warning(
                "chat push send failed (attempt %d/%d): %s",
                row.attempts,
                max_attempts,
                exc,
            )
        else:
            _mark_sent(row)
        session.add(row)

    await session.commit()
    return len(rows)


def _mark_sent(row: ChatPushOutbox) -> None:
    row.status = PUSH_SENT
    row.sent_at = datetime.now(UTC)


async def run_chat_push_dispatcher(stop: asyncio.Event) -> None:
    client = JPushClient.from_settings(settings)
    logger.info("chat push dispatcher started (jpush_configured=%s)", client.configured)
    while not stop.is_set():
        processed = 0
        try:
            async with async_session_maker() as session:
                processed = await dispatch_pending_chat(session, client.send_push)
        except Exception:  # noqa: BLE001
            logger.exception("chat push dispatch pass failed")
        if processed == 0:
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(stop.wait(), timeout=settings.push_poll_interval_seconds)
    logger.info("chat push dispatcher stopped")
