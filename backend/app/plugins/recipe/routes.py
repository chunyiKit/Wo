"""Recipe plugin routes — CRUD over family recipes.

URL space follows the contract: `/families/{family_id}/plugins/recipe/...`.
Every route enforces membership via `require_membership`.
"""

import contextlib
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, File, UploadFile
from sqlmodel import select
from starlette.responses import Response

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.core.storage import storage
from app.plugins.photo.service import validate_image
from app.plugins.recipe.models import (
    Recipe,
    RecipeCreate,
    RecipeRead,
    RecipeTagCreate,
    RecipeUpdate,
)
from app.plugins.recipe.service import (
    add_tag,
    build_cover_storage_key,
    build_read,
    delete_tag,
    list_tags,
)
from app.services.membership import member_info_map as member_map

router = APIRouter(
    prefix="/families/{family_id}/plugins/recipe",
    tags=["recipe"],
)


# ---- Tags (family-shared category palette) ------------------------------


@router.get("/tags", response_model=ApiResponse[list[str]])
async def get_tags(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[str]]:
    await require_membership(session, current_user.id, family_id)
    return ok(await list_tags(session, family_id))


@router.post("/tags", response_model=ApiResponse[list[str]], status_code=201)
async def create_tag(
    family_id: UUID,
    payload: RecipeTagCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[str]]:
    await require_membership(session, current_user.id, family_id)
    name = payload.name.strip()
    if not name:
        raise AppError(ErrorCode.VALIDATION_ERROR, "标签不能为空", status_code=400)
    return ok(await add_tag(session, family_id, name))


@router.delete("/tags", response_model=ApiResponse[list[str]])
async def remove_tag(
    family_id: UUID,
    name: str,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[str]]:
    """Delete a tag from the palette. `name` is a query param (UTF-8 safe)."""
    await require_membership(session, current_user.id, family_id)
    return ok(await delete_tag(session, family_id, name))


@router.get("/recipes", response_model=ApiResponse[list[RecipeRead]])
async def list_recipes(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    category: str | None = None,
) -> ApiResponse[list[RecipeRead]]:
    await require_membership(session, current_user.id, family_id)
    stmt = (
        select(Recipe)
        .where(Recipe.family_id == family_id)
        .order_by(Recipe.created_at.desc())
    )
    if category:
        stmt = stmt.where(Recipe.category == category)
    rows = (await session.execute(stmt)).scalars().all()
    members = await member_map(session, family_id)
    return ok([build_read(r, members) for r in rows])


@router.get("/recipes/{recipe_id}", response_model=ApiResponse[RecipeRead])
async def get_recipe(
    family_id: UUID,
    recipe_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RecipeRead]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(Recipe, recipe_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "菜谱不存在", status_code=404)
    members = await member_map(session, family_id)
    return ok(build_read(row, members))


@router.post(
    "/recipes",
    response_model=ApiResponse[RecipeRead],
    status_code=201,
)
async def create_recipe(
    family_id: UUID,
    payload: RecipeCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RecipeRead]:
    await require_membership(session, current_user.id, family_id)
    # model_dump serializes nested Ingredient models into plain dicts for JSONB.
    row = Recipe(
        **payload.model_dump(),
        family_id=family_id,
        created_by=current_user.id,
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    members = await member_map(session, family_id)
    return ok(build_read(row, members))


@router.put("/recipes/{recipe_id}", response_model=ApiResponse[RecipeRead])
async def update_recipe(
    family_id: UUID,
    recipe_id: UUID,
    payload: RecipeUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RecipeRead]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(Recipe, recipe_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "菜谱不存在", status_code=404)
    updates = payload.model_dump(exclude_unset=True)
    # ingredients arrives as Ingredient models; flatten to dicts for the column.
    if "ingredients" in updates and updates["ingredients"] is not None:
        updates["ingredients"] = [
            i.model_dump() for i in payload.ingredients or []
        ]
    for key, value in updates.items():
        setattr(row, key, value)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    members = await member_map(session, family_id)
    return ok(build_read(row, members))


@router.delete("/recipes/{recipe_id}", response_model=ApiResponse[dict])
async def delete_recipe(
    family_id: UUID,
    recipe_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(Recipe, recipe_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "菜谱不存在", status_code=404)
    cover_key = row.cover_storage_key
    await session.delete(row)
    await session.commit()
    # Best-effort cover cleanup; an orphan blob won't undo the observed delete.
    if cover_key is not None:
        with contextlib.suppress(Exception):
            await storage.delete(cover_key)
    return ok({"deleted": str(recipe_id)})


# ---- Cover photo ---------------------------------------------------------


@router.post("/recipes/{recipe_id}/cover", response_model=ApiResponse[RecipeRead])
async def upload_cover(
    family_id: UUID,
    recipe_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    file: Annotated[UploadFile, File(...)],
) -> ApiResponse[RecipeRead]:
    """Upload/replace a recipe's cover photo. Bumps `cover_version`."""
    await require_membership(session, current_user.id, family_id)
    row = await session.get(Recipe, recipe_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "菜谱不存在", status_code=404)

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

    content_type, ext, _w, _h = validate_image(content)
    new_key = build_cover_storage_key(family_id, recipe_id, ext)
    old_key = row.cover_storage_key

    await storage.put(new_key, content, content_type)
    try:
        row.cover_storage_key = new_key
        row.cover_content_type = content_type
        row.cover_version += 1
        session.add(row)
        await session.commit()
        await session.refresh(row)
    except Exception:
        await storage.delete(new_key)
        raise

    # If the new upload used a different extension, the old blob is now orphaned.
    if old_key is not None and old_key != new_key:
        with contextlib.suppress(Exception):
            await storage.delete(old_key)

    members = await member_map(session, family_id)
    return ok(build_read(row, members))


@router.delete("/recipes/{recipe_id}/cover", response_model=ApiResponse[RecipeRead])
async def delete_cover(
    family_id: UUID,
    recipe_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RecipeRead]:
    """Remove the cover photo; the recipe falls back to its emoji."""
    await require_membership(session, current_user.id, family_id)
    row = await session.get(Recipe, recipe_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "菜谱不存在", status_code=404)

    old_key = row.cover_storage_key
    row.cover_storage_key = None
    row.cover_content_type = None
    session.add(row)
    await session.commit()
    await session.refresh(row)

    if old_key is not None:
        with contextlib.suppress(Exception):
            await storage.delete(old_key)

    members = await member_map(session, family_id)
    return ok(build_read(row, members))


@router.get("/recipes/{recipe_id}/cover")
async def get_cover_raw(
    family_id: UUID,
    recipe_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    """Serve the cover's raw bytes. Membership-checked; binary (not enveloped).

    The URL carries a `?v=` version, so the bytes for a given URL never change
    — clients may cache aggressively.
    """
    await require_membership(session, current_user.id, family_id)
    row = await session.get(Recipe, recipe_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "菜谱不存在", status_code=404)
    if row.cover_storage_key is None:
        raise AppError(ErrorCode.NOT_FOUND, "该菜谱没有封面照片", status_code=404)
    try:
        data = await storage.get(row.cover_storage_key)
    except FileNotFoundError as exc:
        raise AppError(ErrorCode.INTERNAL, "封面文件丢失", status_code=500) from exc
    return Response(
        content=data,
        media_type=row.cover_content_type or "application/octet-stream",
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )
