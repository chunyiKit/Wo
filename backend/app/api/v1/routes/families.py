"""Family CRUD-lite endpoints — create, fetch, switch."""

import contextlib
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, File, UploadFile
from fastapi.responses import RedirectResponse, Response
from sqlmodel import select

from app.api.deps import SessionDep
from app.core import storage as storage_module
from app.core.auth import CurrentUserDep
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.ids import new_uuid7
from app.core.images import validate_image
from app.core.permissions import require_admin, require_membership
from app.core.response import ApiResponse, ok
from app.core.storage import PresignableStorage
from app.models.family import Family, FamilyCreate, FamilyRead, FamilyUpdate
from app.services import family as family_service

router = APIRouter(prefix="/families", tags=["families"])


async def _locked_family(session: SessionDep, family_id: UUID) -> Family:
    family = (
        await session.execute(select(Family).where(Family.id == family_id).with_for_update())
    ).scalar_one_or_none()
    if family is None:
        raise AppError(ErrorCode.FAMILY_NOT_FOUND, "家庭不存在", status_code=404)
    return family


@router.post("/{family_id}/background", response_model=ApiResponse[FamilyRead])
async def upload_background(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    file: Annotated[UploadFile, File(...)],
) -> ApiResponse[FamilyRead]:
    membership = await require_membership(session, current_user.id, family_id)
    require_admin(membership)
    content = await file.read(settings.max_upload_bytes + 1)
    if len(content) > settings.max_upload_bytes:
        raise AppError(ErrorCode.FILE_TOO_LARGE, "图片超过上传大小上限", status_code=413)
    if not content:
        raise AppError(ErrorCode.INVALID_IMAGE, "上传内容为空", status_code=400)
    content_type, ext, _width, _height = validate_image(content)
    family = await _locked_family(session, family_id)
    old_key = family.background_storage_key
    # 每次上传使用独立对象，避免覆盖缓存或并发上传时误删当前图片。
    new_key = f"families/{family_id}/backgrounds/{new_uuid7()}.{ext}"
    storage = storage_module.storage
    await storage.put(new_key, content, content_type)
    try:
        family.background_storage_key = new_key
        family.background_content_type = content_type
        family.background_version += 1
        session.add(family)
        await session.commit()
    except Exception:
        await session.rollback()
        with contextlib.suppress(Exception):
            await storage.delete(new_key)
        raise
    if old_key:
        with contextlib.suppress(Exception):
            await storage.delete(old_key)
    return await get_family(family_id, session, current_user)


@router.delete("/{family_id}/background", response_model=ApiResponse[FamilyRead])
async def reset_background(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[FamilyRead]:
    membership = await require_membership(session, current_user.id, family_id)
    require_admin(membership)
    family = await _locked_family(session, family_id)
    old_key = family.background_storage_key
    family.background_storage_key = None
    family.background_content_type = None
    family.background_version += 1
    session.add(family)
    await session.commit()
    if old_key:
        with contextlib.suppress(Exception):
            await storage_module.storage.delete(old_key)
    return await get_family(family_id, session, current_user)


@router.get("/{family_id}/background")
async def read_background(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    v: int | None = None,
) -> Response:
    await require_membership(session, current_user.id, family_id)
    family = await session.get(Family, family_id)
    if (
        family is None
        or family.background_storage_key is None
        or (v is not None and v != family.background_version)
    ):
        raise AppError(ErrorCode.NOT_FOUND, "背景图片不存在", status_code=404)
    storage = storage_module.storage
    if isinstance(storage, PresignableStorage):
        url = await storage.presigned_get_url(family.background_storage_key, ttl_seconds=3600)
        return RedirectResponse(
            url, status_code=302, headers={"Cache-Control": "private, no-store"}
        )
    try:
        data = await storage.get(family.background_storage_key)
    except FileNotFoundError as exc:
        raise AppError(ErrorCode.NOT_FOUND, "背景图片不存在", status_code=404) from exc
    return Response(
        data,
        media_type=family.background_content_type,
        headers={
            "Cache-Control": "private, max-age=31536000, immutable" if v is not None else "no-store"
        },
    )


@router.post("", response_model=ApiResponse[FamilyRead], status_code=201)
async def create_family(
    payload: FamilyCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[FamilyRead]:
    family, membership = await family_service.create_family(session, payload, current_user)
    # Freshly-created family has exactly one member (the creator/owner).
    return ok(FamilyRead.from_components(family, membership, member_count=1, pet_count=0))


@router.get("/{family_id}", response_model=ApiResponse[FamilyRead])
async def get_family(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[FamilyRead]:
    family, membership, count, pet_count = await family_service.get_family_view(
        session, family_id, current_user
    )
    return ok(FamilyRead.from_components(family, membership, count, pet_count))


@router.patch("/{family_id}", response_model=ApiResponse[FamilyRead])
async def update_family(
    family_id: UUID,
    payload: FamilyUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[FamilyRead]:
    family, membership, count, pet_count = await family_service.update_family(
        session, family_id, payload, current_user
    )
    return ok(FamilyRead.from_components(family, membership, count, pet_count))


@router.post("/{family_id}/switch", response_model=ApiResponse[FamilyRead])
async def switch_family(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[FamilyRead]:
    family, membership, count, pet_count = await family_service.switch_current_family(
        session, current_user, family_id
    )
    return ok(FamilyRead.from_components(family, membership, count, pet_count))
