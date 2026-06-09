"""Travel plugin routes — /families/{family_id}/plugins/travel/...

New flow: create a trip with one photo + city + optional place; a background task
restyles the photo (default prompt + place) and replaces the image. The client
polls the list to see ai_status flip generating → ready. Every route enforces
family membership.
"""

from __future__ import annotations

import contextlib
from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Body, File, Form, UploadFile
from pydantic import BaseModel
from sqlmodel import select
from starlette.responses import RedirectResponse, Response

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.ids import new_uuid7
from app.core.images import validate_image
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.core.storage import PresignableStorage, storage
from app.plugins.memory.models import Memory
from app.plugins.travel.models import TravelTrip
from app.plugins.travel.service import (
    TripRead,
    build_storage_key,
    generate_for_trip,
    linked_memory_map,
    to_trip_read,
)


class SetMemoryBody(BaseModel):
    """Body for PUT /trips/{id}/memory — set (or clear, with null) the link."""

    memory_id: UUID | None = None

router = APIRouter(prefix="/families/{family_id}/plugins/travel", tags=["travel"])


async def _load_trip(
    session: SessionDep, family_id: UUID, trip_id: UUID
) -> TravelTrip:
    trip = await session.get(TravelTrip, trip_id)
    if trip is None or trip.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "旅行记录不存在", status_code=404)
    return trip


async def _resolve_family_memory(
    session: SessionDep, family_id: UUID, memory_id: UUID | None
) -> UUID | None:
    """Return memory_id only if it exists in this family; else None.

    Guards against linking a memory from another family (or a stale id). Visibility
    isn't enforced here — the client can only pick memories it can already see.
    """
    if memory_id is None:
        return None
    mem = await session.get(Memory, memory_id)
    if mem is None or mem.family_id != family_id:
        return None
    return memory_id


@router.get("/trips", response_model=ApiResponse[list[TripRead]])
async def list_trips(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[TripRead]]:
    await require_membership(session, current_user.id, family_id)
    rows = (
        (
            await session.execute(
                select(TravelTrip)
                .where(TravelTrip.family_id == family_id)
                .order_by(TravelTrip.created_at.desc())
            )
        )
        .scalars()
        .all()
    )
    linked = await linked_memory_map(
        session, family_id, current_user.id, [t.memory_id for t in rows]
    )
    return ok([to_trip_read(t, linked.get(t.memory_id)) for t in rows])


@router.post("/trips", response_model=ApiResponse[TripRead], status_code=201)
async def create_trip(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    background: BackgroundTasks,
    file: Annotated[UploadFile, File(...)],
    city_name: Annotated[str, Form()],
    city_lng: Annotated[float, Form()],
    city_lat: Annotated[float, Form()],
    place: Annotated[str | None, Form()] = None,
    caption: Annotated[str | None, Form()] = None,
    memory_id: Annotated[UUID | None, Form()] = None,
) -> ApiResponse[TripRead]:
    """Pin one photo to a city, then kick off background AI restyling."""
    await require_membership(session, current_user.id, family_id)

    cap = settings.max_upload_bytes
    content = await file.read(cap + 1)
    if not content:
        raise AppError(ErrorCode.INVALID_IMAGE, "上传内容为空", status_code=400)
    if len(content) > cap:
        raise AppError(
            ErrorCode.FILE_TOO_LARGE,
            f"文件超过上限 {cap // (1024 * 1024)} MB",
            status_code=413,
        )
    content_type, ext, width, height = validate_image(content)

    name = city_name.strip()
    if not name:
        raise AppError(ErrorCode.VALIDATION_ERROR, "请填写城市", status_code=400)

    linked_id = await _resolve_family_memory(session, family_id, memory_id)
    trip_id = new_uuid7()
    storage_key = build_storage_key(family_id, trip_id, "original", ext)
    await storage.put(storage_key, content, content_type)
    try:
        trip = TravelTrip(
            id=trip_id,
            family_id=family_id,
            city_name=name[:40],
            city_lng=city_lng,
            city_lat=city_lat,
            place=(place or "").strip()[:60] or None,
            caption=(caption or "").strip()[:200] or None,
            original_key=storage_key,
            original_content_type=content_type,
            original_width=width,
            original_height=height,
            ai_status="generating",
            memory_id=linked_id,
            created_by=current_user.id,
        )
        session.add(trip)
        await session.commit()
        await session.refresh(trip)
    except Exception:
        with contextlib.suppress(Exception):
            await storage.delete(storage_key)
        raise

    # Restyle in the background; the client polls the list for ai_status.
    background.add_task(generate_for_trip, trip_id)
    linked = await linked_memory_map(
        session, family_id, current_user.id, [trip.memory_id]
    )
    return ok(to_trip_read(trip, linked.get(trip.memory_id)))


@router.post("/trips/{trip_id}/retry", response_model=ApiResponse[TripRead])
async def retry_trip(
    family_id: UUID,
    trip_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    background: BackgroundTasks,
) -> ApiResponse[TripRead]:
    """Re-run generation for a trip whose AI image failed (or to regenerate)."""
    await require_membership(session, current_user.id, family_id)
    trip = await _load_trip(session, family_id, trip_id)
    trip.ai_status = "generating"
    session.add(trip)
    await session.commit()
    await session.refresh(trip)
    background.add_task(generate_for_trip, trip_id)
    linked = await linked_memory_map(
        session, family_id, current_user.id, [trip.memory_id]
    )
    return ok(to_trip_read(trip, linked.get(trip.memory_id)))


@router.put("/trips/{trip_id}/memory", response_model=ApiResponse[TripRead])
async def set_trip_memory(
    family_id: UUID,
    trip_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    body: Annotated[SetMemoryBody, Body()],
) -> ApiResponse[TripRead]:
    """Set (or clear, with memory_id=null) the trip's 1:1 link to a memory."""
    await require_membership(session, current_user.id, family_id)
    trip = await _load_trip(session, family_id, trip_id)
    if body.memory_id is not None:
        linked_id = await _resolve_family_memory(
            session, family_id, body.memory_id
        )
        if linked_id is None:
            raise AppError(ErrorCode.NOT_FOUND, "回忆不存在", status_code=404)
        trip.memory_id = linked_id
    else:
        trip.memory_id = None
    trip.updated_at = datetime.now(UTC)
    session.add(trip)
    await session.commit()
    await session.refresh(trip)
    linked = await linked_memory_map(
        session, family_id, current_user.id, [trip.memory_id]
    )
    return ok(to_trip_read(trip, linked.get(trip.memory_id)))


@router.delete("/trips/{trip_id}", response_model=ApiResponse[dict])
async def delete_trip(
    family_id: UUID,
    trip_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    trip = await _load_trip(session, family_id, trip_id)
    key = trip.original_key
    await session.delete(trip)
    await session.commit()
    with contextlib.suppress(Exception):
        await storage.delete(key)
    return ok({"deleted": str(trip_id)})


@router.get("/trips/{trip_id}/image")
async def get_trip_image(
    family_id: UUID,
    trip_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    """Serve the trip's current image (original, then AI once ready). Members
    only. COS → 302; local disk → inline stream."""
    await require_membership(session, current_user.id, family_id)
    trip = await _load_trip(session, family_id, trip_id)

    if isinstance(storage, PresignableStorage):
        url = await storage.presigned_get_url(trip.original_key, ttl_seconds=3600)
        return RedirectResponse(url, status_code=302)
    try:
        data = await storage.get(trip.original_key)
    except FileNotFoundError as exc:
        raise AppError(ErrorCode.INTERNAL, "图片文件丢失", status_code=500) from exc
    return Response(content=data, media_type=trip.original_content_type)
