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
    DEFAULT_PLACEMENTS,
    MAX_LOG_PHOTOS,
    MAX_PLACEMENT_LEN,
    MAX_PLACEMENTS,
    Plant,
    PlantCreate,
    PlantFamilySettings,
    PlantFamilySettingsRead,
    PlantFamilySettingsUpdate,
    PlantLog,
    PlantLogRead,
    PlantRead,
    PlantUpdate,
    PlantWeatherRead,
)
from app.plugins.plant.service import (
    arm_due_dates,
    build_log_read,
    build_plant_read,
    build_storage_key,
)
from app.services.weather import (
    WeatherError,
    WeatherNotConfiguredError,
    get_weather,
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
    files: Annotated[list[UploadFile], File(...)],
    note: Annotated[str | None, Form()] = None,
) -> ApiResponse[PlantLogRead]:
    """Add a dated care log with one or more photos. Photos are persisted to
    storage in this request (the durable history record), the row is created
    with `ai_status="pending"`, and a background task then has the AI analyze
    ALL photos together. Photo persistence is independent of AI success."""
    from app.core.config import settings

    await require_membership(session, current_user.id, family_id)
    plant = await _load_plant(session, family_id, plant_id)

    if not files:
        raise AppError(ErrorCode.INVALID_IMAGE, "至少上传一张照片", status_code=400)
    if len(files) > MAX_LOG_PHOTOS:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            f"一次最多 {MAX_LOG_PHOTOS} 张照片",
            status_code=400,
        )

    # Read + validate every file first, so we don't persist a partial set.
    blobs: list[tuple[bytes, str, str]] = []  # (content, content_type, ext)
    for f in files:
        content = await f.read(settings.max_upload_bytes + 1)
        if not content:
            raise AppError(ErrorCode.INVALID_IMAGE, "上传内容为空", status_code=400)
        if len(content) > settings.max_upload_bytes:
            raise AppError(
                ErrorCode.FILE_TOO_LARGE,
                f"文件超过上限 {settings.max_upload_bytes // (1024 * 1024)} MB",
                status_code=413,
            )
        content_type, ext, _w, _h = validate_image(content)
        blobs.append((content, content_type, ext))

    log_id = new_uuid7()
    photos: list[dict[str, str]] = []
    written_keys: list[str] = []
    try:
        for i, (content, content_type, ext) in enumerate(blobs):
            key = build_storage_key(family_id, plant_id, log_id, ext, index=i)
            await storage.put(key, content, content_type)
            written_keys.append(key)
            photos.append({"key": key, "content_type": content_type})

        first = photos[0]
        log = PlantLog(
            id=log_id,
            plant_id=plant_id,
            family_id=family_id,
            photos=photos,
            # Legacy single-photo fields mirror the first photo (cover/thumb).
            photo_storage_key=first["key"],
            photo_content_type=first["content_type"],
            photo_version=1,
            note=(note.strip() if note else None) or None,
            ai_status="pending",
        )
        session.add(log)
        # Give the plant a cover from its first photo.
        if not plant.cover_storage_key:
            plant.cover_storage_key = first["key"]
            plant.cover_content_type = first["content_type"]
            plant.cover_version += 1
            session.add(plant)
        await session.commit()
        await session.refresh(log)
    except Exception:
        # Roll back any blobs we wrote so nothing leaks on failure.
        for key in written_keys:
            with contextlib.suppress(Exception):
                await storage.delete(key)
        raise
    # Runs after the response is sent; opens its own DB session.
    background.add_task(analyze_log, log.id)
    return ok(build_log_read(log))


@router.delete("/plants/{plant_id}/logs/{log_id}", response_model=ApiResponse[dict])
async def delete_log(
    family_id: UUID,
    plant_id: UUID,
    log_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    """Delete a care log: removes the row + its photo blobs. Any in-flight AI
    analysis becomes a no-op (its background task re-reads the row by id and
    finds it gone, or its result update hits the deleted row and affects nothing),
    so deleting also effectively cancels the analysis. If the plant's cover came
    from this log, it's repointed to the latest remaining log (or cleared)."""
    await require_membership(session, current_user.id, family_id)
    log = await _load_log(session, family_id, plant_id, log_id)
    plant = await _load_plant(session, family_id, plant_id)

    keys = [p["key"] for p in (log.photos or []) if p.get("key")]
    if log.photo_storage_key and log.photo_storage_key not in keys:
        keys.append(log.photo_storage_key)
    cover_from_this = (
        plant.cover_storage_key is not None and plant.cover_storage_key in keys
    )

    await session.delete(log)
    await session.flush()  # so the cover-repoint query excludes the deleted log

    if cover_from_this:
        # Repoint the plant cover to the newest remaining log's photo, else clear.
        stmt = (
            select(PlantLog)
            .where(
                PlantLog.plant_id == plant_id,
                PlantLog.photo_storage_key.is_not(None),
            )
            .order_by(PlantLog.created_at.desc())
        )
        nxt = (await session.execute(stmt)).scalars().first()
        plant.cover_storage_key = nxt.photo_storage_key if nxt else None
        plant.cover_content_type = nxt.photo_content_type if nxt else None
        plant.cover_version += 1
        session.add(plant)

    await session.commit()

    # Drop blobs after the DB commit (so a commit failure doesn't orphan the row).
    for key in keys:
        with contextlib.suppress(Exception):
            await storage.delete(key)
    return ok({"deleted": str(log_id)})


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


@router.get("/plants/{plant_id}/logs/{log_id}/photos/{index}")
async def get_log_photo_at(
    family_id: UUID,
    plant_id: UUID,
    log_id: UUID,
    index: int,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    """Serve the i-th photo of a multi-photo care log."""
    await require_membership(session, current_user.id, family_id)
    log = await _load_log(session, family_id, plant_id, log_id)
    photos = log.photos or (
        [{"key": log.photo_storage_key, "content_type": log.photo_content_type}]
        if log.photo_storage_key
        else []
    )
    if index < 0 or index >= len(photos):
        raise AppError(ErrorCode.NOT_FOUND, "照片不存在", status_code=404)
    spec = photos[index]
    return await _serve_blob(spec.get("key"), spec.get("content_type"))


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


def _sanitize_placements(raw: list[str]) -> list[str]:
    """Trim, drop empties, dedupe (keep order), clamp length & count. Family-shared
    so we validate at the boundary."""
    out: list[str] = []
    for item in raw:
        label = item.strip()[:MAX_PLACEMENT_LEN]
        if label and label not in out:
            out.append(label)
        if len(out) >= MAX_PLACEMENTS:
            break
    return out


def _settings_read(row: PlantFamilySettings | None) -> PlantFamilySettingsRead:
    """Serialize settings, injecting the default placement presets when the
    family hasn't customized them (stored as NULL)."""
    if row is None:
        return PlantFamilySettingsRead(placements=list(DEFAULT_PLACEMENTS))
    return PlantFamilySettingsRead(
        latitude=row.latitude,
        longitude=row.longitude,
        location_label=row.location_label,
        placements=row.placements or list(DEFAULT_PLACEMENTS),
    )


@router.get("/settings", response_model=ApiResponse[PlantFamilySettingsRead])
async def get_settings(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PlantFamilySettingsRead]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(PlantFamilySettings, family_id)
    return ok(_settings_read(row))


@router.put("/settings", response_model=ApiResponse[PlantFamilySettingsRead])
async def update_settings(
    family_id: UUID,
    payload: PlantFamilySettingsUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PlantFamilySettingsRead]:
    """Set the family's default environment (location) and/or its shared
    placement presets. New plants inherit the location for weather lookups."""
    await require_membership(session, current_user.id, family_id)
    row = await session.get(PlantFamilySettings, family_id)
    updates = payload.model_dump(exclude_unset=True)
    if "placements" in updates and updates["placements"] is not None:
        updates["placements"] = _sanitize_placements(updates["placements"])
    if row is None:
        row = PlantFamilySettings(family_id=family_id, **updates)
    else:
        for key, value in updates.items():
            setattr(row, key, value)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(_settings_read(row))


@router.get("/weather", response_model=ApiResponse[PlantWeatherRead])
async def get_weather_now(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PlantWeatherRead]:
    """Current weather at the family's saved location, for the plugin's weather
    card. Degrades gracefully (available=False + reason) when no location is set,
    the provider isn't configured, or the lookup fails."""
    await require_membership(session, current_user.id, family_id)
    row = await session.get(PlantFamilySettings, family_id)
    if row is None or row.latitude is None or row.longitude is None:
        return ok(PlantWeatherRead(available=False, reason="尚未设置位置"))

    base = PlantWeatherRead(
        location_label=row.location_label,
        latitude=row.latitude,
        longitude=row.longitude,
    )
    try:
        snap = await get_weather(row.latitude, row.longitude)
    except WeatherNotConfiguredError:
        return ok(base.model_copy(update={"reason": "天气服务未配置"}))
    except WeatherError:
        return ok(base.model_copy(update={"reason": "天气暂时获取失败,稍后再试"}))

    return ok(
        base.model_copy(
            update={
                "available": True,
                "temp_c": snap.temp_c,
                "feels_like_c": snap.feels_like_c,
                "condition": snap.condition,
                "icon": snap.icon,
                "humidity_pct": snap.humidity_pct,
                "precip_mm": snap.precip_mm,
                "pressure_hpa": snap.pressure_hpa,
                "visibility_km": snap.visibility_km,
                "cloud_pct": snap.cloud_pct,
                "dew_point_c": snap.dew_point_c,
                "wind_dir": snap.wind_dir,
                "wind_scale": snap.wind_scale,
                "wind_speed_kmh": snap.wind_speed_kmh,
                "wind_deg": snap.wind_deg,
                "uv_index": snap.uv_index,
                "observed_at": snap.observed_at,
            }
        )
    )


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
