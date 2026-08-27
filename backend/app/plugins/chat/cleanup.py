"""Retention cleanup for chat server-side sync data."""

from __future__ import annotations

import asyncio
import contextlib
import logging

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.config import settings
from app.core.database import async_session_maker
from app.core.storage import storage
from app.plugins.chat.models import ChatImage, ChatMessage
from app.plugins.chat.service import retention_cutoff

logger = logging.getLogger(__name__)


async def cleanup_expired_chat(session: AsyncSession) -> int:
    """Delete expired messages and their blobs. Returns number of messages."""
    cutoff = retention_cutoff()
    stmt = select(ChatMessage).where(ChatMessage.created_at < cutoff).limit(500)
    messages = list((await session.execute(stmt)).scalars().all())
    if not messages:
        return 0

    ids = [m.id for m in messages]
    images = list(
        (await session.execute(select(ChatImage).where(ChatImage.message_id.in_(ids))))
        .scalars()
        .all()
    )
    keys = [img.storage_key for img in images]

    for message in messages:
        await session.delete(message)
    await session.commit()

    for key in keys:
        with contextlib.suppress(Exception):
            await storage.delete(key)
    return len(messages)


async def run_chat_cleanup_loop(stop: asyncio.Event) -> None:
    logger.info("chat cleanup loop started")
    while not stop.is_set():
        try:
            async with async_session_maker() as session:
                while await cleanup_expired_chat(session):
                    pass
        except Exception:  # noqa: BLE001
            logger.exception("chat cleanup pass failed")
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(stop.wait(), timeout=settings.chat_cleanup_poll_seconds)
    logger.info("chat cleanup loop stopped")
