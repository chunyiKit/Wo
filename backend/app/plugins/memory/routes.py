"""Memory plugin routes — timeline CRUD + media upload + comments.

URL space: `/families/{family_id}/plugins/memory/...` (mounted under `/api/v1`).
Every route enforces family membership. `private` memories are filtered to their
author both on the list and on direct fetch.

Media upload uses multipart/form-data: a single `file` part plus optional
`duration_ms` (for videos, since the server doesn't probe clip length). The
raw-bytes endpoint streams via a plain Response since the body is binary.
"""

import contextlib
from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, File, Form, Query, UploadFile
from sqlalchemy import func
from sqlmodel import select
from starlette.responses import RedirectResponse, Response

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.ids import new_uuid7
from app.core.permissions import require_membership
from app.core.response import ApiResponse, Meta, ok
from app.core.storage import PresignableStorage, storage
from app.plugins.memory.models import (
    VISIBILITY_VALUES,
    Memory,
    MemoryComment,
    MemoryCommentCreate,
    MemoryCommentRead,
    MemoryCreate,
    MemoryMedia,
    MemoryMediaRead,
    MemoryRead,
    MemoryUpdate,
)
from app.plugins.memory.service import (
    build_read,
    build_storage_key,
    decode_cursor,
    encode_cursor,
    member_map,
    to_comment_read,
    to_media_read,
    today,
    validate_media,
    visible_to,
)

router = APIRouter(
    prefix="/families/{family_id}/plugins/memory",
    tags=["memory"],
)

# Timeline page size: the default the app requests, and a hard cap so a crafted
# `limit` can't pull the whole table in one shot.
TIMELINE_PAGE_DEFAULT = 20
TIMELINE_PAGE_MAX = 50


# ---- Loaders / guards -----------------------------------------------------


async def _load_memory(session: SessionDep, family_id: UUID, memory_id: UUID) -> Memory:
    row = await session.get(Memory, memory_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "回忆不存在", status_code=404)
    return row


async def _media_for(session: SessionDep, memory_id: UUID) -> list[MemoryMedia]:
    stmt = (
        select(MemoryMedia)
        .where(MemoryMedia.memory_id == memory_id)
        .order_by(MemoryMedia.sort_order, MemoryMedia.created_at)
    )
    return list((await session.execute(stmt)).scalars().all())


async def _comment_count(session: SessionDep, memory_id: UUID) -> int:
    stmt = (
        select(func.count()).select_from(MemoryComment).where(MemoryComment.memory_id == memory_id)
    )
    return int((await session.execute(stmt)).scalar_one())


def _normalize_visibility(value: str | None) -> str:
    """Reject unknown visibility values rather than silently storing junk."""
    if value is None:
        return "family"
    if value not in VISIBILITY_VALUES:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            "可见范围不合法",
            status_code=400,
            details={"allowed": list(VISIBILITY_VALUES)},
        )
    return value


# ---- Memories -------------------------------------------------------------


@router.get("/memories", response_model=ApiResponse[list[MemoryRead]])
async def list_memories(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=TIMELINE_PAGE_MAX)] = TIMELINE_PAGE_DEFAULT,
) -> ApiResponse[list[MemoryRead]]:
    """Timeline page, newest first by event_date then recency. Keyset-paginated:
    pass the previous page's `meta.cursor` to fetch the next `limit` entries;
    `meta.cursor` is null once the oldest entry is reached. `private` memories
    only show to their author. Each entry carries its media + comment count, and
    `meta.total` is the full visible count (drives the "共 N 条" header)."""
    await require_membership(session, current_user.id, family_id)

    private_ok = (Memory.visibility != "private") | (Memory.created_by == current_user.id)

    stmt = select(Memory).where(Memory.family_id == family_id, private_ok)
    if cursor is not None:
        c_date, c_created, c_id = decode_cursor(cursor)
        # "Strictly older than the cursor row" under ORDER BY
        # (event_date, created_at, id) all-DESC — written out instead of a
        # row-value comparison so it behaves identically on every backend.
        stmt = stmt.where(
            (Memory.event_date < c_date)
            | ((Memory.event_date == c_date) & (Memory.created_at < c_created))
            | (
                (Memory.event_date == c_date)
                & (Memory.created_at == c_created)
                & (Memory.id < c_id)
            )
        )
    # +1 sentinel row tells us whether a further page exists without a second query.
    stmt = stmt.order_by(
        Memory.event_date.desc(), Memory.created_at.desc(), Memory.id.desc()
    ).limit(limit + 1)

    rows = list((await session.execute(stmt)).scalars().all())
    has_more = len(rows) > limit
    page = rows[:limit]

    # Full visible count for the header — cheap on the family_id/visibility index
    # and independent of the page window, so it stays correct as the user scrolls.
    total_stmt = (
        select(func.count()).select_from(Memory).where(Memory.family_id == family_id, private_ok)
    )
    total = int((await session.execute(total_stmt)).scalar_one())
    next_cursor = encode_cursor(page[-1]) if (has_more and page) else None
    meta = Meta(total=total, cursor=next_cursor, limit=limit)

    if not page:
        return ok([], meta=meta)

    ids = [m.id for m in page]

    media_stmt = (
        select(MemoryMedia)
        .where(MemoryMedia.memory_id.in_(ids))
        .order_by(MemoryMedia.sort_order, MemoryMedia.created_at)
    )
    media_by_memory: dict[UUID, list[MemoryMedia]] = {mid: [] for mid in ids}
    for media in (await session.execute(media_stmt)).scalars().all():
        media_by_memory[media.memory_id].append(media)

    count_stmt = (
        select(MemoryComment.memory_id, func.count())
        .where(MemoryComment.memory_id.in_(ids))
        .group_by(MemoryComment.memory_id)
    )
    counts = {row[0]: int(row[1]) for row in (await session.execute(count_stmt)).all()}

    members = await member_map(session, family_id)
    return ok(
        [
            build_read(
                m,
                media_by_memory[m.id],
                members,
                comment_count=counts.get(m.id, 0),
            )
            for m in page
        ],
        meta=meta,
    )


@router.post("/memories", response_model=ApiResponse[MemoryRead], status_code=201)
async def create_memory(
    family_id: UUID,
    payload: MemoryCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[MemoryRead]:
    await require_membership(session, current_user.id, family_id)
    title = payload.title.strip()
    if not title:
        raise AppError(ErrorCode.VALIDATION_ERROR, "标题不能为空", status_code=400)

    row = Memory(
        title=title,
        body=payload.body,
        mood=payload.mood,
        location=payload.location,
        visibility=_normalize_visibility(payload.visibility),
        event_date=payload.event_date or today(),
        family_id=family_id,
        created_by=current_user.id,
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)

    members = await member_map(session, family_id)
    return ok(build_read(row, [], members, comment_count=0))


@router.get("/memories/{memory_id}", response_model=ApiResponse[MemoryRead])
async def get_memory(
    family_id: UUID,
    memory_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[MemoryRead]:
    """Full memory incl. media and comments. 404 for a `private` memory the
    caller didn't author (don't leak existence)."""
    await require_membership(session, current_user.id, family_id)
    memory = await _load_memory(session, family_id, memory_id)
    if not visible_to(memory, current_user.id):
        raise AppError(ErrorCode.NOT_FOUND, "回忆不存在", status_code=404)

    media = await _media_for(session, memory_id)
    comment_stmt = (
        select(MemoryComment)
        .where(MemoryComment.memory_id == memory_id)
        .order_by(MemoryComment.created_at)
    )
    comments = list((await session.execute(comment_stmt)).scalars().all())
    members = await member_map(session, family_id)
    return ok(
        build_read(
            memory,
            media,
            members,
            comment_count=len(comments),
            comments=comments,
        )
    )


@router.put("/memories/{memory_id}", response_model=ApiResponse[MemoryRead])
async def update_memory(
    family_id: UUID,
    memory_id: UUID,
    payload: MemoryUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[MemoryRead]:
    await require_membership(session, current_user.id, family_id)
    memory = await _load_memory(session, family_id, memory_id)

    updates = payload.model_dump(exclude_unset=True)
    if "title" in updates:
        title = (updates["title"] or "").strip()
        if not title:
            raise AppError(ErrorCode.VALIDATION_ERROR, "标题不能为空", status_code=400)
        updates["title"] = title
    if "visibility" in updates:
        updates["visibility"] = _normalize_visibility(updates["visibility"])
    if "event_date" in updates and updates["event_date"] is None:
        # An explicit null event_date is meaningless — drop it rather than wipe.
        del updates["event_date"]

    for key, value in updates.items():
        setattr(memory, key, value)
    memory.updated_at = datetime.now(UTC)
    session.add(memory)
    await session.commit()
    await session.refresh(memory)

    media = await _media_for(session, memory_id)
    members = await member_map(session, family_id)
    count = await _comment_count(session, memory_id)
    return ok(build_read(memory, media, members, comment_count=count))


@router.delete("/memories/{memory_id}", response_model=ApiResponse[dict])
async def delete_memory(
    family_id: UUID,
    memory_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    """Delete a memory. Media + comments cascade in the DB; we sweep the media
    blobs best-effort after the row is gone."""
    await require_membership(session, current_user.id, family_id)
    memory = await _load_memory(session, family_id, memory_id)

    media = await _media_for(session, memory_id)
    keys = [m.storage_key for m in media]

    await session.delete(memory)
    await session.commit()

    for key in keys:
        with contextlib.suppress(Exception):
            await storage.delete(key)

    return ok({"deleted": str(memory_id)})


# ---- Media ----------------------------------------------------------------


@router.post(
    "/memories/{memory_id}/media",
    response_model=ApiResponse[MemoryMediaRead],
    status_code=201,
)
async def upload_media(
    family_id: UUID,
    memory_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    file: Annotated[UploadFile, File(...)],
    duration_ms: Annotated[int | None, Form()] = None,
) -> ApiResponse[MemoryMediaRead]:
    """Attach a photo or video. Kind is detected from the bytes, not trusted
    from the client. Appended to the end of the memory's media order."""
    await require_membership(session, current_user.id, family_id)
    memory = await _load_memory(session, family_id, memory_id)

    # Read up to the video cap (the larger of the two limits) so we can size-check
    # by kind once we know what it is.
    video_cap = settings.memory_video_max_bytes
    content = await file.read(video_cap + 1)
    if not content:
        raise AppError(ErrorCode.INVALID_IMAGE, "上传内容为空", status_code=400)

    kind, content_type, ext, width, height = validate_media(content)

    cap = video_cap if kind == "video" else settings.max_upload_bytes
    if len(content) > cap:
        raise AppError(
            ErrorCode.FILE_TOO_LARGE,
            f"文件超过上限 {cap // (1024 * 1024)} MB",
            status_code=413,
            details={"max_bytes": cap, "kind": kind},
        )

    # Next sort_order = current max + 1 (0 when none yet).
    max_order = (
        await session.execute(
            select(func.coalesce(func.max(MemoryMedia.sort_order), -1)).where(
                MemoryMedia.memory_id == memory_id
            )
        )
    ).scalar_one()

    media_id = new_uuid7()
    storage_key = build_storage_key(family_id, memory_id, media_id, ext)

    # Write the blob first; if the DB write fails we delete it so nothing leaks.
    await storage.put(storage_key, content, content_type)
    try:
        media = MemoryMedia(
            id=media_id,
            memory_id=memory_id,
            family_id=family_id,
            kind=kind,
            storage_key=storage_key,
            content_type=content_type,
            size_bytes=len(content),
            width=width,
            height=height,
            duration_ms=duration_ms if kind == "video" else None,
            sort_order=int(max_order) + 1,
            created_by=current_user.id,
        )
        session.add(media)
        # Touch the parent so its updated_at reflects the new attachment.
        memory.updated_at = datetime.now(UTC)
        session.add(memory)
        await session.commit()
        await session.refresh(media)
    except Exception:
        await storage.delete(storage_key)
        raise

    return ok(to_media_read(media))


@router.delete("/memories/{memory_id}/media/{media_id}", response_model=ApiResponse[dict])
async def delete_media(
    family_id: UUID,
    memory_id: UUID,
    media_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    media = await session.get(MemoryMedia, media_id)
    if media is None or media.memory_id != memory_id or media.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "媒体不存在", status_code=404)

    storage_key = media.storage_key
    await session.delete(media)
    await session.commit()
    with contextlib.suppress(Exception):
        await storage.delete(storage_key)
    return ok({"deleted": str(media_id)})


@router.get("/memories/{memory_id}/media/{media_id}/raw")
async def get_media_raw(
    family_id: UUID,
    memory_id: UUID,
    media_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    """Serve a memory's photo or video bytes.

    Membership-checked; private memories only resolve for their author. When
    the storage backend supports presigned URLs (COS), we **302-redirect**
    to a 1-hour signed URL so the bytes come straight from object storage
    and never touch this CVM's bandwidth. Local-disk fallback (dev/tests)
    still streams bytes inline.

    `CachedNetworkImage` and other dart:io clients follow the 302 transparently
    and cache against the original `/raw` URL, so the App doesn't need to
    know that COS is in the loop.
    """
    await require_membership(session, current_user.id, family_id)
    media = await session.get(MemoryMedia, media_id)
    if media is None or media.memory_id != memory_id or media.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "媒体不存在", status_code=404)
    memory = await _load_memory(session, family_id, memory_id)
    if not visible_to(memory, current_user.id):
        raise AppError(ErrorCode.NOT_FOUND, "媒体不存在", status_code=404)

    if isinstance(storage, PresignableStorage):
        url = await storage.presigned_get_url(media.storage_key, ttl_seconds=3600)
        return RedirectResponse(url, status_code=302)

    try:
        data = await storage.get(media.storage_key)
    except FileNotFoundError as exc:
        raise AppError(ErrorCode.INTERNAL, "媒体文件丢失", status_code=500) from exc
    return Response(content=data, media_type=media.content_type)


# ---- Comments -------------------------------------------------------------


@router.post(
    "/memories/{memory_id}/comments",
    response_model=ApiResponse[MemoryCommentRead],
    status_code=201,
)
async def add_comment(
    family_id: UUID,
    memory_id: UUID,
    payload: MemoryCommentCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[MemoryCommentRead]:
    await require_membership(session, current_user.id, family_id)
    memory = await _load_memory(session, family_id, memory_id)
    if not visible_to(memory, current_user.id):
        raise AppError(ErrorCode.NOT_FOUND, "回忆不存在", status_code=404)

    body = payload.body.strip()
    if not body:
        raise AppError(ErrorCode.VALIDATION_ERROR, "留言不能为空", status_code=400)

    comment = MemoryComment(
        memory_id=memory_id,
        family_id=family_id,
        body=body,
        created_by=current_user.id,
    )
    session.add(comment)
    await session.commit()
    await session.refresh(comment)

    members = await member_map(session, family_id)
    return ok(to_comment_read(comment, members, family_id))


@router.delete("/memories/{memory_id}/comments/{comment_id}", response_model=ApiResponse[dict])
async def delete_comment(
    family_id: UUID,
    memory_id: UUID,
    comment_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    """Only the comment's author can remove it."""
    await require_membership(session, current_user.id, family_id)
    comment = await session.get(MemoryComment, comment_id)
    if comment is None or comment.memory_id != memory_id or comment.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "留言不存在", status_code=404)
    if comment.created_by != current_user.id:
        raise AppError(ErrorCode.FORBIDDEN, "只能删除自己的留言", status_code=403)

    await session.delete(comment)
    await session.commit()
    return ok({"deleted": str(comment_id)})
