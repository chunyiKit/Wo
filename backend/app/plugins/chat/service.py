"""Chat plugin business logic: sync-window queries, serialization, and media."""

from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.models.membership import Membership
from app.models.plugin import InstalledPlugin
from app.plugins.chat.models import (
    KIND_IMAGE,
    KIND_TEXT,
    ChatImage,
    ChatImageRead,
    ChatMessage,
    ChatMessageRead,
)
from app.plugins.registry import PluginPreview
from app.services.membership import MemberInfo, author_avatar_url


def retention_cutoff() -> datetime:
    """Earliest server-retained chat timestamp."""
    return datetime.now(UTC) - timedelta(days=settings.chat_retention_days)


def build_storage_key(family_id: UUID, message_id: UUID, ext: str) -> str:
    return f"chat/{family_id}/{message_id}/image.{ext}"


def build_image_url(family_id: UUID, message_id: UUID) -> str:
    return f"/api/v1/families/{family_id}/plugins/chat/messages/{message_id}/image/raw"


def to_image_read(image: ChatImage) -> ChatImageRead:
    return ChatImageRead(
        message_id=image.message_id,
        content_type=image.content_type,
        size_bytes=image.size_bytes,
        width=image.width,
        height=image.height,
        url=build_image_url(image.family_id, image.message_id),
    )


def to_message_read(
    message: ChatMessage,
    image: ChatImage | None,
    members: dict[UUID, MemberInfo],
) -> ChatMessageRead:
    info = members.get(message.sender_id) if message.sender_id is not None else None
    return ChatMessageRead(
        id=message.id,
        family_id=message.family_id,
        sender_id=message.sender_id,
        client_id=message.client_id,
        kind=message.kind,
        body=message.body,
        sender_name=message.sender_name,
        sender_emoji=message.sender_emoji,
        sender_avatar_url=author_avatar_url(message.family_id, message.sender_id, info),
        created_at=message.created_at,
        image=to_image_read(image) if image is not None else None,
    )


async def load_existing_by_client_id(
    session: AsyncSession,
    *,
    family_id: UUID,
    sender_id: UUID,
    client_id: str,
) -> ChatMessage | None:
    stmt = select(ChatMessage).where(
        ChatMessage.family_id == family_id,
        ChatMessage.sender_id == sender_id,
        ChatMessage.client_id == client_id,
    )
    return (await session.execute(stmt)).scalar_one_or_none()


def create_text_message(
    *,
    family_id: UUID,
    membership: Membership,
    client_id: str,
    body: str,
) -> ChatMessage:
    text = body.strip()
    if not text:
        raise AppError(ErrorCode.VALIDATION_ERROR, "消息内容不能为空", status_code=400)
    return ChatMessage(
        family_id=family_id,
        sender_id=membership.user_id,
        client_id=client_id.strip(),
        kind=KIND_TEXT,
        body=text,
        sender_name=membership.display_name,
        sender_emoji=membership.avatar_emoji,
    )


def create_image_message(
    *,
    message_id: UUID,
    family_id: UUID,
    membership: Membership,
    client_id: str,
    body: str | None,
) -> ChatMessage:
    text = (body or "").strip() or None
    return ChatMessage(
        id=message_id,
        family_id=family_id,
        sender_id=membership.user_id,
        client_id=client_id.strip(),
        kind=KIND_IMAGE,
        body=text,
        sender_name=membership.display_name,
        sender_emoji=membership.avatar_emoji,
    )


async def image_for(session: AsyncSession, message_id: UUID) -> ChatImage | None:
    return await session.get(ChatImage, message_id)


async def image_map_for(session: AsyncSession, message_ids: list[UUID]) -> dict[UUID, ChatImage]:
    if not message_ids:
        return {}
    stmt = select(ChatImage).where(ChatImage.message_id.in_(message_ids))
    return {img.message_id: img for img in (await session.execute(stmt)).scalars().all()}


async def preview_hook(
    session: AsyncSession, ip: InstalledPlugin, _viewer_id: UUID | None = None
) -> PluginPreview:
    stmt = (
        select(ChatMessage)
        .where(
            ChatMessage.family_id == ip.family_id,
            ChatMessage.created_at >= retention_cutoff(),
        )
        .order_by(ChatMessage.created_at.desc(), ChatMessage.id.desc())
        .limit(1)
    )
    latest = (await session.execute(stmt)).scalars().first()
    if latest is None:
        return PluginPreview(
            primary="还没有聊天",
            secondary="和家人说第一句话",
            color_token="accent",
            emoji="💬",
        )
    primary = latest.body if latest.kind == KIND_TEXT and latest.body else "发来一张图片"
    return PluginPreview(
        primary=primary[:32],
        secondary=latest.sender_name,
        color_token="accent",
        emoji="💬",
    )
