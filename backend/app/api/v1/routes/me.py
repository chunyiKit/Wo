"""Current-user endpoints — `/me`, `/me/families`, `/me/bootstrap`.

`/me/bootstrap` is the first-frame aggregator (contract §6.1): one request
returns user + current_family + families + installed_plugins + unread_count,
so the Flutter splash screen doesn't fan out to 4 endpoints in parallel.
"""

import contextlib
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, File, UploadFile
from pydantic import BaseModel
from sqlmodel import select
from starlette.responses import Response

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.images import validate_image
from app.core.response import ApiResponse, ok
from app.core.storage import storage
from app.models.family import FamilyRead
from app.models.plugin import InstalledPlugin
from app.models.user import UserRead, UserUpdate
from app.plugins.views import InstalledPluginRead, to_installed_read
from app.services import family as family_service
from app.services import notification as notification_service
from app.services import user as user_service
from app.services.user import build_avatar_storage_key

router = APIRouter(tags=["me"])


class StatsRead(BaseModel):
    families_joined: int
    plugins_used: int = 0  # P3 will populate this
    days_active: int


class MeResponse(BaseModel):
    user: UserRead
    current_family: FamilyRead | None
    stats: StatsRead


class BootstrapResponse(BaseModel):
    """Everything the splash screen needs in a single round-trip."""

    user: UserRead
    current_family: FamilyRead | None
    families: list[FamilyRead]
    installed_plugins: list[InstalledPluginRead]
    unread_count: int


def _days_since(then: datetime) -> int:
    return max(0, (datetime.now(UTC) - then).days)


@router.get("/me", response_model=ApiResponse[MeResponse])
async def me(
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[MeResponse]:
    families = await family_service.list_user_families(session, current_user)

    current: FamilyRead | None = None
    if current_user.current_family_id is not None:
        for f, m, cnt in families:
            if f.id == current_user.current_family_id:
                current = FamilyRead.from_components(f, m, cnt)
                break

    stats = StatsRead(
        families_joined=len(families),
        days_active=_days_since(current_user.created_at),
    )
    return ok(
        MeResponse(
            user=UserRead.from_user(current_user),
            current_family=current,
            stats=stats,
        )
    )


@router.patch("/me", response_model=ApiResponse[UserRead])
async def update_me(
    payload: UserUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[UserRead]:
    """更新当前用户资料（目前支持昵称 display_name）。仅更新提供的字段。

    改昵称会同步到「仍沿用旧昵称」的家庭成员身份上，使记账等按成员展示
    名字的地方同步刷新（见 user_service.update_me）。
    """
    user = await user_service.update_me(session, current_user, payload)
    return ok(UserRead.from_user(user))


@router.get("/me/families", response_model=ApiResponse[list[FamilyRead]])
async def my_families(
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[FamilyRead]]:
    families = await family_service.list_user_families(session, current_user)
    return ok([FamilyRead.from_components(f, m, cnt) for f, m, cnt in families])


@router.get("/me/bootstrap", response_model=ApiResponse[BootstrapResponse])
async def bootstrap(
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[BootstrapResponse]:
    """First-frame aggregator — see contract §6.1."""
    families = await family_service.list_user_families(session, current_user)

    current_family: FamilyRead | None = None
    installed_plugins: list[InstalledPluginRead] = []
    if current_user.current_family_id is not None:
        for f, m, cnt in families:
            if f.id == current_user.current_family_id:
                current_family = FamilyRead.from_components(f, m, cnt)
                stmt = (
                    select(InstalledPlugin)
                    .where(InstalledPlugin.family_id == f.id)
                    .order_by(InstalledPlugin.row, InstalledPlugin.col)
                )
                rows = (await session.execute(stmt)).scalars().all()
                installed_plugins = [
                    await to_installed_read(session, r, current_user.id) for r in rows
                ]
                break

    unread = await notification_service.count_unread(session, current_user.id)

    return ok(
        BootstrapResponse(
            user=UserRead.from_user(current_user),
            current_family=current_family,
            families=[FamilyRead.from_components(f, m, cnt) for f, m, cnt in families],
            installed_plugins=installed_plugins,
            unread_count=unread,
        )
    )


# ---- Avatar --------------------------------------------------------------


@router.post("/me/avatar", response_model=ApiResponse[UserRead])
async def upload_avatar(
    session: SessionDep,
    current_user: CurrentUserDep,
    file: Annotated[UploadFile, File(...)],
) -> ApiResponse[UserRead]:
    """上传/替换当前用户头像。每次上传 `avatar_version` +1，客户端据此刷新缓存。"""
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
    new_key = build_avatar_storage_key(current_user.id, ext)
    old_key = current_user.avatar_storage_key

    await storage.put(new_key, content, content_type)
    try:
        current_user.avatar_storage_key = new_key
        current_user.avatar_content_type = content_type
        current_user.avatar_version += 1
        session.add(current_user)
        await session.commit()
        await session.refresh(current_user)
    except Exception:
        await storage.delete(new_key)
        raise

    # If the new upload used a different extension, the old blob is now orphaned.
    if old_key is not None and old_key != new_key:
        with contextlib.suppress(Exception):
            await storage.delete(old_key)

    return ok(UserRead.from_user(current_user))


@router.delete("/me/avatar", response_model=ApiResponse[UserRead])
async def delete_avatar(
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[UserRead]:
    """移除头像，回退到 `avatar_emoji`。"""
    old_key = current_user.avatar_storage_key
    current_user.avatar_storage_key = None
    current_user.avatar_content_type = None
    session.add(current_user)
    await session.commit()
    await session.refresh(current_user)

    if old_key is not None:
        with contextlib.suppress(Exception):
            await storage.delete(old_key)

    return ok(UserRead.from_user(current_user))


@router.get("/me/avatar")
async def get_avatar_raw(
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    """返回头像原始字节（非信封）。URL 带 `?v=` 版本号，故可长期缓存。"""
    if current_user.avatar_storage_key is None:
        raise AppError(ErrorCode.NOT_FOUND, "尚未设置头像", status_code=404)
    try:
        data = await storage.get(current_user.avatar_storage_key)
    except FileNotFoundError as exc:
        raise AppError(ErrorCode.INTERNAL, "头像文件丢失", status_code=500) from exc
    return Response(
        content=data,
        media_type=current_user.avatar_content_type or "application/octet-stream",
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )
