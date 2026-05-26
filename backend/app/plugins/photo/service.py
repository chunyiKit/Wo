"""Photo plugin service — image validation, preview hook, helper builders.

Routes call into these. Validation happens here so we don't sprinkle
Pillow-import logic across the codebase.
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

# Re-exported so existing importers (recipe plugin) keep working unchanged.
from app.core.images import validate_image
from app.models.plugin import InstalledPlugin
from app.models.user import User
from app.plugins.photo.models import Photo, PhotoRead
from app.plugins.registry import PluginPreview

__all__ = [
    "build_photo_url",
    "build_storage_key",
    "preview_hook",
    "to_photo_read",
    "validate_image",
]


def build_storage_key(family_id: UUID, photo_id: UUID, ext: str) -> str:
    """Namespace photos by family for easy backup/cleanup boundaries."""
    return f"photos/{family_id}/{photo_id}.{ext}"


def build_photo_url(family_id: UUID, photo_id: UUID) -> str:
    """Relative URL of the photo's raw-bytes endpoint."""
    return f"/api/v1/families/{family_id}/plugins/photo/photos/{photo_id}/raw"


def to_photo_read(photo: Photo) -> PhotoRead:
    return PhotoRead(
        id=photo.id,
        family_id=photo.family_id,
        album_id=photo.album_id,
        caption=photo.caption,
        content_type=photo.content_type,
        size_bytes=photo.size_bytes,
        width=photo.width,
        height=photo.height,
        uploaded_at=photo.uploaded_at,
        uploaded_by=photo.uploaded_by,
        url=build_photo_url(photo.family_id, photo.id),
    )


# ---- Preview --------------------------------------------------------------


def _humanize_delta(delta: timedelta) -> str:
    seconds = int(delta.total_seconds())
    if seconds < 60:
        return "刚刚"
    if seconds < 3600:
        return f"{seconds // 60} 分钟前"
    if seconds < 86400:
        return f"{seconds // 3600} 小时前"
    return f"{seconds // 86400} 天前"


async def preview_hook(
    session: AsyncSession, ip: InstalledPlugin, _viewer_id: UUID | None = None
) -> PluginPreview:
    """Show total + this-week's photos + latest uploader timing."""
    family_id = ip.family_id
    total_stmt = select(func.count()).select_from(Photo).where(Photo.family_id == family_id)
    total = int((await session.execute(total_stmt)).scalar_one())

    if total == 0:
        return PluginPreview(
            primary="还没有照片",
            secondary="点击上传第一张",
            color_token="photo",
        )

    week_ago = datetime.now(UTC) - timedelta(days=7)
    week_stmt = (
        select(func.count())
        .select_from(Photo)
        .where(Photo.family_id == family_id, Photo.uploaded_at >= week_ago)
    )
    week_count = int((await session.execute(week_stmt)).scalar_one())

    latest_stmt = (
        select(Photo, User.display_name)
        .join(User, Photo.uploaded_by == User.id, isouter=True)
        .where(Photo.family_id == family_id)
        .order_by(Photo.uploaded_at.desc())
        .limit(1)
    )
    row = (await session.execute(latest_stmt)).first()
    if row is None:
        # Should not happen given total > 0, but stay defensive.
        return PluginPreview(
            primary=f"共 {total} 张",
            color_token="photo",
        )
    photo, uploader_name = row
    when = _humanize_delta(datetime.now(UTC) - photo.uploaded_at)
    primary = f"本周新照片 · {week_count}" if week_count > 0 else f"共 {total} 张照片"
    secondary = f"{uploader_name or '匿名'} · {when}"
    return PluginPreview(primary=primary, secondary=secondary, color_token="photo")
