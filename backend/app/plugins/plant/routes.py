"""Plant journal plugin routes — plants, care logs (with photo), care cycles,
and the family default environment.

URL space: `/families/{family_id}/plugins/plant/...` (mounted under `/api/v1`).
Every route enforces family membership.
"""

import contextlib
from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, File, Form, UploadFile
from pydantic import BaseModel
from sqlmodel import select
from starlette.responses import RedirectResponse, Response

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.errors import AppError, ErrorCode
from app.core.ids import new_uuid7
from app.core.images import validate_image
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.core.storage import PresignableStorage, storage
from app.plugins.plant.ai import analyze_log
from app.plugins.plant.models import (
    Plant,
    PlantCreate,
    PlantFamilySettings,
    PlantFamilySettingsRead,
    PlantFamilySettingsUpdate,
    PlantLog,
    PlantLogRead,
    PlantRead,
    PlantUpdate,
)
from app.plugins.plant.service import (
    arm_due_dates,
    build_log_read,
    build_plant_read,
    build_storage_key,
)

router = APIRouter(
    prefix="/families/{family_id}/plugins/plant",
    tags=["plant"],
)


class AdoptSuggestionRequest(BaseModel):
    """Which AI-suggested cycles to adopt onto the plant. Both default True."""

    water: bool = True
    fert: bool = True


async def _load_plant(session: SessionDep, family_id: UUID, plant_id: UUID) -> Plant:
    row = await session.get(Plant, plant_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "植物不存在", status_code=404)
    return row


async def _load_log(
    session: SessionDep, family_id: UUID, plant_id: UUID, log_id: UUID
) -> PlantLog:
    row = await session.get(PlantLog, log_id)
    if row is None or row.family_id != family_id or row.plant_id != plant_id:
        raise AppError(ErrorCode.NOT_FOUND, "记录不存在", status_code=404)
    return row


# ---- plants ----------------------------------------------------------------


@router.get("/plants", response_model=ApiResponse[list[PlantRead]])
async def list_plants(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[PlantRead]]:
    await require_membership(session, current_user.id, family_id)
    stmt = (
        select(Plant)
        .where(Plant.family_id == family_id)
        .order_by(Plant.created_at.desc())
    )
    rows = (await session.execute(stmt)).scalars().all()
    return ok([build_plant_read(r) for r in rows])


@router.post("/plants", response_model=ApiResponse[PlantRead], status_code=201)
async def create_plant(
    family_id: UUID,
    payload: PlantCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PlantRead]:
    await require_membership(session, current_user.id, family_id)
    name = payload.name.strip()
    if not name:
        raise AppError(ErrorCode.VALIDATION_ERROR, "名称不能为空", status_code=400)
    row = Plant(
        **payload.model_dump(exclude={"name"}),
        name=name,
        family_id=family_id,
    )
    # Setting intervals at creation arms the reminders.
    arm_due_dates(row, today=date.today())
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(build_plant_read(row))


@router.get("/plants/{plant_id}", response_model=ApiResponse[PlantRead])
async def get_plant(
    family_id: UUID,
    plant_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PlantRead]:
    await require_membership(session, current_user.id, family_id)
    row = await _load_plant(session, family_id, plant_id)
    return ok(build_plant_read(row))


@router.put("/plants/{plant_id}", response_model=ApiResponse[PlantRead])
async def update_plant(
    family_id: UUID,
    plant_id: UUID,
    payload: PlantUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PlantRead]:
    """Partial update. Changing a care interval re-arms (or disarms) the matching
    reminder by recomputing `next_*_due`."""
    await require_membership(session, current_user.id, family_id)
    row = await _load_plant(session, family_id, plant_id)
    updates = payload.model_dump(exclude_unset=True)
    if "name" in updates and updates["name"] is not None:
        name = updates["name"].strip()
        if not name:
            raise AppError(ErrorCode.VALIDATION_ERROR, "名称不能为空", status_code=400)
        updates["name"] = name
    intervals_touched = "water_interval_days" in updates or "fert_interval_days" in updates
    for key, value in updates.items():
        setattr(row, key, value)
    if intervals_touched:
        arm_due_dates(row, today=date.today())
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(build_plant_read(row))


@router.delete("/plants/{plant_id}", response_model=ApiResponse[dict])
async def delete_plant(
    family_id: UUID,
    plant_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    row = await _load_plant(session, family_id, plant_id)
    # Drop all log photo blobs (best-effort) so a delete doesn't leak storage.
    logs = (
        await session.execute(
            select(PlantLog).where(PlantLog.plant_id == plant_id)
        )
    ).scalars().all()
    for log in logs:
        if log.photo_storage_key:
            with contextlib.suppress(Exception):
                await storage.delete(log.photo_storage_key)
    await session.delete(row)  # cascades to plant_logs rows
    await session.commit()
    return ok({"deleted": str(plant_id)})


@router.get("/plants/{plant_id}/cover")
async def get_plant_cover(
    family_id: UUID,
    plant_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    await require_membership(session, current_user.id, family_id)
    row = await _load_plant(session, family_id, plant_id)
    if not row.cover_storage_key:
        raise AppError(ErrorCode.NOT_FOUND, "封面不存在", status_code=404)
    return await _serve_blob(row.cover_storage_key, row.cover_content_type)


# ---- care logs -------------------------------------------------------------


@router.get("/plants/{plant_id}/logs", response_model=ApiResponse[list[PlantLogRead]])
async def list_logs(
    family_id: UUID,
    plant_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[PlantLogRead]]:
    """Care timeline, newest first."""
    await require_membership(session, current_user.id, family_id)
    await _load_plant(session, family_id, plant_id)
    stmt = (
        select(PlantLog)
        .where(PlantLog.plant_id == plant_id)
        .order_by(PlantLog.created_at.desc())
    )
    rows = (await session.execute(stmt)).scalars().all()
    return ok([build_log_read(r) for r in rows])


@router.post(
    "/plants/{plant_id}/logs",
    response_model=ApiResponse[PlantLogRead],
    status_code=201,
)
async def create_log(
    family_id: UUID,
    plant_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    background: BackgroundTasks,
    file: Annotated[UploadFile, File(...)],
    note: Annotated[str | None, Form()] = None,
) -> ApiResponse[PlantLogRead]:
    """Add a dated care log with a photo. The photo is persisted to storage in
    this request (the durable history record), the row is created with
    `ai_status="pending"`, and a background task then fills the AI assessment +
    advice. Photo persistence is independent of AI success."""
    from app.core.config import settings

    await require_membership(session, current_user.id, family_id)
    plant = await _load_plant(session, family_id, plant_id)

    content = await file.read(settings.max_upload_bytes + 1)
    if not content:
        raise AppError(ErrorCode.INVALID_IMAGE, "上传内容为空", status_code=400)
    if len(content) > settings.max_upload_bytes:
        raise AppError(
            ErrorCode.FILE_TOO_LARGE,
            f"文件超过上限 {settings.max_upload_bytes // (1024 * 1024)} MB",
            status_code=413,
        )
    content_type, ext, _w, _h = validate_image(content)

    log_id = new_uuid7()
    storage_key = build_storage_key(family_id, plant_id, log_id, ext)
    # Persist the blob first; if the DB write fails we delete it so nothing leaks.
    await storage.put(storage_key, content, content_type)
    try:
        log = PlantLog(
            id=log_id,
            plant_id=plant_id,
            family_id=family_id,
            photo_storage_key=storage_key,
            photo_content_type=content_type,
            photo_version=1,
            note=(note.strip() if note else None) or None,
            ai_status="pending",
        )
        session.add(log)
        # Give the plant a cover from its first photo.
        if not plant.cover_storage_key:
            plant.cover_storage_key = storage_key
            plant.cover_content_type = content_type
            plant.cover_version += 1
            session.add(plant)
        await session.commit()
        await session.refresh(log)
    except Exception:
        with contextlib.suppress(Exception):
            await storage.delete(storage_key)
        raise
    # Runs after the response is sent; opens its own DB session.
    background.add_task(analyze_log, log.id)
    return ok(build_log_read(log))


@router.get("/plants/{plant_id}/logs/{log_id}/photo")
async def get_log_photo(
    family_id: UUID,
    plant_id: UUID,
    log_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    await require_membership(session, current_user.id, family_id)
    log = await _load_log(session, family_id, plant_id, log_id)
    if not log.photo_storage_key:
        raise AppError(ErrorCode.NOT_FOUND, "照片不存在", status_code=404)
    return await _serve_blob(log.photo_storage_key, log.photo_content_type)


@router.post(
    "/plants/{plant_id}/logs/{log_id}/reanalyze",
    response_model=ApiResponse[PlantLogRead],
)
async def reanalyze_log(
    family_id: UUID,
    plant_id: UUID,
    log_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    background: BackgroundTasks,
) -> ApiResponse[PlantLogRead]:
    """Re-run AI analysis for a log (e.g. after a failure)."""
    await require_membership(session, current_user.id, family_id)
    log = await _load_log(session, family_id, plant_id, log_id)
    log.ai_status = "pending"
    session.add(log)
    await session.commit()
    await session.refresh(log)
    background.add_task(analyze_log, log.id)
    return ok(build_log_read(log))


@router.post(
    "/plants/{plant_id}/logs/{log_id}/adopt",
    response_model=ApiResponse[PlantRead],
)
async def adopt_suggestion(
    family_id: UUID,
    plant_id: UUID,
    log_id: UUID,
    payload: AdoptSuggestionRequest,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PlantRead]:
    """Adopt a log's AI-suggested care cycle(s) onto the plant, then re-arm the
    matching reminder. The user's explicit action — suggestions are never
    auto-applied."""
    await require_membership(session, current_user.id, family_id)
    plant = await _load_plant(session, family_id, plant_id)
    log = await _load_log(session, family_id, plant_id, log_id)

    changed = False
    if payload.water and log.ai_suggested_water_days:
        plant.water_interval_days = log.ai_suggested_water_days
        changed = True
    if payload.fert and log.ai_suggested_fert_days:
        plant.fert_interval_days = log.ai_suggested_fert_days
        changed = True
    if not changed:
        raise AppError(
            ErrorCode.VALIDATION_ERROR, "没有可采纳的建议值", status_code=400
        )
    arm_due_dates(plant, today=date.today())
    session.add(plant)
    await session.commit()
    await session.refresh(plant)
    return ok(build_plant_read(plant))


# ---- family default environment --------------------------------------------


@router.get("/settings", response_model=ApiResponse[PlantFamilySettingsRead])
async def get_settings(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PlantFamilySettingsRead]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(PlantFamilySettings, family_id)
    if row is None:
        return ok(PlantFamilySettingsRead())
    return ok(PlantFamilySettingsRead.model_validate(row, from_attributes=True))


@router.put("/settings", response_model=ApiResponse[PlantFamilySettingsRead])
async def update_settings(
    family_id: UUID,
    payload: PlantFamilySettingsUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PlantFamilySettingsRead]:
    """Set the family's default environment (location). New plants inherit it
    for weather lookups."""
    await require_membership(session, current_user.id, family_id)
    row = await session.get(PlantFamilySettings, family_id)
    updates = payload.model_dump(exclude_unset=True)
    if row is None:
        row = PlantFamilySettings(family_id=family_id, **updates)
    else:
        for key, value in updates.items():
            setattr(row, key, value)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(PlantFamilySettingsRead.model_validate(row, from_attributes=True))


# ---- helpers ---------------------------------------------------------------


async def _serve_blob(key: str, content_type: str | None) -> Response:
    """Serve a blob: 302 to a presigned URL on COS, inline bytes on local disk."""
    if isinstance(storage, PresignableStorage):
        url = await storage.presigned_get_url(key, ttl_seconds=3600)
        return RedirectResponse(url, status_code=302)
    try:
        data = await storage.get(key)
    except FileNotFoundError as exc:
        raise AppError(ErrorCode.INTERNAL, "图片文件丢失", status_code=500) from exc
    return Response(content=data, media_type=content_type or "image/jpeg")
