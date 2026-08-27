"""Core family Pet identity and photo endpoints."""

import contextlib
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, File, UploadFile
from starlette.responses import RedirectResponse, Response

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.images import validate_image
from app.core.permissions import require_admin, require_membership
from app.core.response import ApiResponse, ok
from app.core.storage import PresignableStorage, storage
from app.models.pet import PetCreate, PetRead, PetUpdate, to_pet_read
from app.services import pet as pet_service

router = APIRouter(prefix="/families", tags=["pets"])


@router.get("/{family_id}/pets", response_model=ApiResponse[list[PetRead]])
async def list_pets(
    family_id: UUID, session: SessionDep, current_user: CurrentUserDep
) -> ApiResponse[list[PetRead]]:
    rows = await pet_service.list_pets(session, family_id, current_user)
    return ok([to_pet_read(row) for row in rows])


@router.post("/{family_id}/pets", response_model=ApiResponse[PetRead], status_code=201)
async def create_pet(
    family_id: UUID,
    payload: PetCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PetRead]:
    return ok(to_pet_read(await pet_service.create_pet(session, family_id, payload, current_user)))


@router.get("/{family_id}/pets/{pet_id}", response_model=ApiResponse[PetRead])
async def get_pet(
    family_id: UUID,
    pet_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PetRead]:
    await require_membership(session, current_user.id, family_id)
    return ok(to_pet_read(await pet_service.load_pet(session, family_id, pet_id)))


@router.patch("/{family_id}/pets/{pet_id}", response_model=ApiResponse[PetRead])
async def update_pet(
    family_id: UUID,
    pet_id: UUID,
    payload: PetUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PetRead]:
    row = await pet_service.update_pet(session, family_id, pet_id, payload, current_user)
    return ok(to_pet_read(row))


@router.delete("/{family_id}/pets/{pet_id}", response_model=ApiResponse[PetRead])
async def archive_pet(
    family_id: UUID,
    pet_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PetRead]:
    row = await pet_service.archive_pet(session, family_id, pet_id, current_user)
    return ok(to_pet_read(row))


@router.post("/{family_id}/pets/{pet_id}/photo", response_model=ApiResponse[PetRead])
async def upload_pet_photo(
    family_id: UUID,
    pet_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    file: Annotated[UploadFile, File(...)],
) -> ApiResponse[PetRead]:
    membership = await require_membership(session, current_user.id, family_id)
    require_admin(membership)
    pet = await pet_service.load_pet(session, family_id, pet_id)
    cap = settings.max_upload_bytes
    content = await file.read(cap + 1)
    if len(content) > cap:
        raise AppError(
            ErrorCode.FILE_TOO_LARGE,
            f"文件超过上限 {cap // (1024 * 1024)} MB",
            status_code=413,
            details={"max_bytes": cap},
        )
    if not content:
        raise AppError(ErrorCode.INVALID_IMAGE, "上传内容为空", status_code=400)
    content_type, ext, _width, _height = validate_image(content)
    new_key = pet_service.photo_storage_key(family_id, pet.id, ext)
    old_key = pet.photo_storage_key
    await storage.put(new_key, content, content_type)
    try:
        pet.photo_storage_key = new_key
        pet.photo_content_type = content_type
        pet.photo_version += 1
        session.add(pet)
        await session.commit()
        await session.refresh(pet)
    except Exception:
        if new_key != old_key:
            with contextlib.suppress(Exception):
                await storage.delete(new_key)
        raise
    if old_key and old_key != new_key:
        with contextlib.suppress(Exception):
            await storage.delete(old_key)
    return ok(to_pet_read(pet))


@router.delete("/{family_id}/pets/{pet_id}/photo", response_model=ApiResponse[PetRead])
async def delete_pet_photo(
    family_id: UUID,
    pet_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PetRead]:
    membership = await require_membership(session, current_user.id, family_id)
    require_admin(membership)
    pet = await pet_service.load_pet(session, family_id, pet_id)
    old_key = pet.photo_storage_key
    pet.photo_storage_key = None
    pet.photo_content_type = None
    pet.photo_version += 1
    session.add(pet)
    await session.commit()
    await session.refresh(pet)
    if old_key:
        with contextlib.suppress(Exception):
            await storage.delete(old_key)
    return ok(to_pet_read(pet))


@router.get("/{family_id}/pets/{pet_id}/photo")
async def get_pet_photo(
    family_id: UUID,
    pet_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    await require_membership(session, current_user.id, family_id)
    pet = await pet_service.load_pet(session, family_id, pet_id, include_archived=True)
    if not pet.photo_storage_key:
        raise AppError(ErrorCode.NOT_FOUND, "尚未设置宠物照片", status_code=404)
    if isinstance(storage, PresignableStorage):
        url = await storage.presigned_get_url(pet.photo_storage_key, ttl_seconds=3600)
        return RedirectResponse(url, status_code=302)
    try:
        data = await storage.get(pet.photo_storage_key)
    except FileNotFoundError as exc:
        raise AppError(ErrorCode.NOT_FOUND, "宠物照片不存在", status_code=404) from exc
    return Response(
        content=data,
        media_type=pet.photo_content_type or "application/octet-stream",
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )
