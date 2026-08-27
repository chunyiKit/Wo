"""Chat plugin routes.

URL space: `/families/{family_id}/plugins/chat/...` (mounted under `/api/v1`).
Every route enforces family membership. The server only exposes messages inside
the current retention window; clients keep long-term local history themselves.
"""

from datetime import datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, File, Form, Query, UploadFile
from sqlmodel import select
from starlette.responses import RedirectResponse, Response

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.ids import new_uuid7
from app.core.images import validate_image
from app.core.permissions import require_membership
from app.core.response import ApiResponse, Meta, ok
from app.core.storage import PresignableStorage, storage
from app.plugins.chat.models import ChatImage, ChatMessage, ChatMessageRead, ChatTextCreate
from app.plugins.chat.push import stage_chat_pushes
from app.plugins.chat.service import (
    build_storage_key,
    create_image_message,
    create_text_message,
    image_for,
    image_map_for,
    load_existing_by_client_id,
    retention_cutoff,
    to_message_read,
)
from app.services.membership import member_info_map

router = APIRouter(prefix="/families/{family_id}/plugins/chat", tags=["chat"])

MESSAGE_PAGE_DEFAULT = 100
MESSAGE_PAGE_MAX = 200


def _cursor_for(message: ChatMessage | None) -> str | None:
    if message is None:
        return None
    return f"{message.created_at.isoformat()}|{message.id}"


async def _read_one(
    session: SessionDep,
    family_id: UUID,
    message: ChatMessage,
) -> ChatMessageRead:
    members = await member_info_map(session, family_id)
    return to_message_read(message, await image_for(session, message.id), members)


@router.get("/messages", response_model=ApiResponse[list[ChatMessageRead]])
async def list_messages(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    after_created_at: datetime | None = None,
    after_id: UUID | None = None,
    limit: Annotated[int, Query(ge=1, le=MESSAGE_PAGE_MAX)] = MESSAGE_PAGE_DEFAULT,
) -> ApiResponse[list[ChatMessageRead]]:
    await require_membership(session, current_user.id, family_id)
    if (after_created_at is None) != (after_id is None):
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            "after_created_at 和 after_id 必须同时提供",
            status_code=400,
        )

    stmt = select(ChatMessage).where(
        ChatMessage.family_id == family_id,
        ChatMessage.created_at >= retention_cutoff(),
    )
    if after_created_at is not None and after_id is not None:
        stmt = stmt.where(
            (ChatMessage.created_at > after_created_at)
            | ((ChatMessage.created_at == after_created_at) & (ChatMessage.id > after_id))
        )
    stmt = stmt.order_by(ChatMessage.created_at, ChatMessage.id).limit(limit + 1)
    rows = list((await session.execute(stmt)).scalars().all())
    has_more = len(rows) > limit
    page = rows[:limit]
    image_by_id = await image_map_for(session, [m.id for m in page])
    members = await member_info_map(session, family_id)
    data = [to_message_read(m, image_by_id.get(m.id), members) for m in page]
    meta = Meta(cursor=_cursor_for(page[-1] if has_more and page else None), limit=limit)
    return ok(data, meta=meta)


@router.post("/messages", response_model=ApiResponse[ChatMessageRead], status_code=201)
async def send_text(
    family_id: UUID,
    payload: ChatTextCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[ChatMessageRead]:
    membership = await require_membership(session, current_user.id, family_id)
    existing = await load_existing_by_client_id(
        session,
        family_id=family_id,
        sender_id=current_user.id,
        client_id=payload.client_id,
    )
    if existing is not None:
        return ok(await _read_one(session, family_id, existing))

    message = create_text_message(
        family_id=family_id,
        membership=membership,
        client_id=payload.client_id,
        body=payload.body,
    )
    session.add(message)
    await stage_chat_pushes(session, message)
    await session.commit()
    await session.refresh(message)
    return ok(await _read_one(session, family_id, message))


@router.post("/messages/image", response_model=ApiResponse[ChatMessageRead], status_code=201)
async def send_image(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    file: Annotated[UploadFile, File(...)],
    client_id: Annotated[str, Form(min_length=1, max_length=80)],
    body: Annotated[str | None, Form(max_length=2000)] = None,
) -> ApiResponse[ChatMessageRead]:
    membership = await require_membership(session, current_user.id, family_id)
    existing = await load_existing_by_client_id(
        session,
        family_id=family_id,
        sender_id=current_user.id,
        client_id=client_id,
    )
    if existing is not None:
        return ok(await _read_one(session, family_id, existing))

    content = await file.read(settings.max_upload_bytes + 1)
    if not content:
        raise AppError(ErrorCode.INVALID_IMAGE, "上传内容为空", status_code=400)
    if len(content) > settings.max_upload_bytes:
        raise AppError(
            ErrorCode.FILE_TOO_LARGE,
            f"文件超过上限 {settings.max_upload_bytes // (1024 * 1024)} MB",
            status_code=413,
            details={"max_bytes": settings.max_upload_bytes},
        )

    content_type, ext, width, height = validate_image(content)
    message_id = new_uuid7()
    storage_key = build_storage_key(family_id, message_id, ext)
    await storage.put(storage_key, content, content_type)
    try:
        message = create_image_message(
            message_id=message_id,
            family_id=family_id,
            membership=membership,
            client_id=client_id,
            body=body,
        )
        image = ChatImage(
            message_id=message_id,
            family_id=family_id,
            storage_key=storage_key,
            content_type=content_type,
            size_bytes=len(content),
            width=width,
            height=height,
        )
        session.add(message)
        await session.flush()
        session.add(image)
        await stage_chat_pushes(session, message)
        await session.commit()
        await session.refresh(message)
    except Exception:
        await storage.delete(storage_key)
        raise

    return ok(await _read_one(session, family_id, message))


@router.get("/messages/{message_id}/image/raw")
async def get_image_raw(
    family_id: UUID,
    message_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    await require_membership(session, current_user.id, family_id)
    message = await session.get(ChatMessage, message_id)
    image = await session.get(ChatImage, message_id)
    if (
        message is None
        or image is None
        or message.family_id != family_id
        or image.family_id != family_id
    ):
        raise AppError(ErrorCode.NOT_FOUND, "图片不存在", status_code=404)

    if isinstance(storage, PresignableStorage):
        url = await storage.presigned_get_url(image.storage_key, ttl_seconds=3600)
        return RedirectResponse(url, status_code=302)
    try:
        data = await storage.get(image.storage_key)
    except FileNotFoundError as exc:
        raise AppError(ErrorCode.INTERNAL, "图片文件丢失", status_code=500) from exc
    return Response(content=data, media_type=image.content_type)
