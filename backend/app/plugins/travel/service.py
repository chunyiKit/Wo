"""Travel plugin — serialization, storage keys, default prompt, async generation.

New flow: the user uploads one photo + city + optional specific place, then a
background task restyles it via the family's image-gen model using a fixed
default prompt (Color Walk 套色章 collage) with the place appended. On success the
generated image REPLACES the original (the original is deleted); on failure the
original is kept and ai_status is marked "failed".
"""

from __future__ import annotations

import contextlib
import logging
from datetime import UTC, datetime
from uuid import UUID

from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.database import async_session_maker
from app.core.storage import storage
from app.models.plugin import InstalledPlugin
from app.plugins.registry import PluginPreview
from app.plugins.travel.models import TravelTrip
from app.services.ai import ai_generate_image

logger = logging.getLogger(__name__)

# Fixed default prompt — every generation uses this; the specific place (if any)
# is appended. Users no longer type prompts.
DEFAULT_PROMPT = (
    "请把我上传的照片生成一张 Color Walk 风格旅行记录拼图。这张图的目标是：上半部分展示"
    "“由照片转译而来的套色章设计”，下半部分展示“原照片来源”。整体像一页干净、克制、有留白的"
    "旅行手账/色彩漫游记录 /文创作品展示页。画面结构，整张图采用竖版拼图，比例接近 4:5 或 3:4。"
    "画面分为上下两部分，高度比例固定为1:1：•上半部分是设计展示区。•下半部分是原照片展示区。"
    "上半部分使用从照片中提取的柔和低饱和背景色，例如雾绿、灰蓝、米黄、淡粉、浅青或暖灰。"
    "在上半部分居中放置一张套色章设计图，印章尺寸不要过大，占上半部分设计区面积不超过30%，"
    "周围保留充足留白。文字放在上半部分内部，位于套色章下方或附近，作为设计氛围的一部分。"
    "英文短语应根据照片画面和情绪自动生成，不要固定套用同一句。下半部分展示原始照片，"
    "可以轻微裁切以适配版式，但必须保留照片主体和最有代表性的场景。套色章设计请先从照片中"
    "提取最有识别度的主体，例如建筑、桥、村落、山水、石林、水面、道路、植物或牌匾。然后把它"
    "重新设计成一张成熟的旅游文创套色章：•像直接盖印在上半部分设计区里的图案，而不是一张贴上去"
    "的邮票。•可以有白色或米白色留白，但不要做成厚纸片、贴纸边、投影卡片或邮票质感。•清晰边框，"
    "可用圆角矩形、八角框、花窗框或横版风景框。•使用3 到 5 个专色叠印。•用平面色块、手绘线描、"
    "留白和少量装饰纹理表现主体。•颜色应有明确分层，例如水面、岩石、树木、建筑、线条分别使用不同"
    "专色。•有轻微印泥颗粒、手工边缘、墨色不均和套印错位感，呈现真实盖章/拓印效果。•整体精致、"
    "干净，像可以用于明信片、手账贴纸或景区纪念章的设计。套色章不是照片滤镜，也不是邮票贴片，"
    "而是照片内容的图形化盖印转译。文字在设计展示区加入一句根据照片意境生成的简短英文，例如："
    "• Color Walk• Recording one's life• Travel Stamp Study文字要清晰可读，有轻复古、手写、"
    "打字机或文创手账气质。文字不需要解释画面，只负责营造记录感和节奏感。如果照片中已有明显文字，"
    "不要重复堆叠大标题。如果地点不确定，不要编造地名。鏊体气质画面应当：•干净。克制。有留白。"
    "有旅行记录感。有设计作品展示感。•上方设计和下方照片形成清楚的“转译前后对照”。避免做成商业"
    "海报、复杂拼贴、信息说明图或普通照片滤镜。"
)

_CT_EXT = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}


def ext_from_ct(content_type: str) -> str:
    return _CT_EXT.get(content_type.split(";")[0].strip(), "png")


def build_prompt(place: str | None) -> str:
    """Default prompt + the specific place appended (if given)."""
    if place and place.strip():
        return f"{DEFAULT_PROMPT}\n地点：{place.strip()}"
    return DEFAULT_PROMPT


def build_storage_key(family_id: UUID, trip_id: UUID, which: str, ext: str) -> str:
    return f"travel/{family_id}/{trip_id}-{which}.{ext}"


def image_url(family_id: UUID, trip_id: UUID, *, v: int | None = None) -> str:
    """Host-relative URL of a trip's current image (original, then AI once ready).

    `v` is a cache-busting version (the trip's updated_at epoch). The image bytes
    behind a fixed path change when the AI image replaces the original, so without
    a changing query the client would keep showing the cached original.
    """
    base = f"/api/v1/families/{family_id}/plugins/travel/trips/{trip_id}/image"
    return f"{base}?v={v}" if v is not None else base


def _ver(trip: TravelTrip) -> int:
    return int(trip.updated_at.timestamp())


class TripRead(BaseModel):
    id: UUID
    family_id: UUID
    city_name: str
    city_lng: float
    city_lat: float
    place: str | None
    caption: str | None
    image_url: str
    ai_status: str  # generating | ready | failed
    created_at: datetime


def to_trip_read(trip: TravelTrip) -> TripRead:
    return TripRead(
        id=trip.id,
        family_id=trip.family_id,
        city_name=trip.city_name,
        city_lng=trip.city_lng,
        city_lat=trip.city_lat,
        place=trip.place,
        caption=trip.caption,
        image_url=image_url(trip.family_id, trip.id, v=_ver(trip)),
        ai_status=trip.ai_status,
        created_at=trip.created_at,
    )


async def generate_for_trip(trip_id: UUID) -> None:
    """Background task: restyle the trip's photo via the family's image model,
    then replace the stored image with the result. Never raises.

    On success the original blob is deleted (we don't keep it). On failure the
    original is kept and ai_status="failed" so the record still has an image.
    """
    async with async_session_maker() as session:
        trip = await session.get(TravelTrip, trip_id)
        if trip is None:
            return
        try:
            original = await storage.get(trip.original_key)
        except FileNotFoundError:
            trip.ai_status = "failed"
            session.add(trip)
            await session.commit()
            return

        prompt = build_prompt(trip.place)
        try:
            img_bytes, img_ct = await ai_generate_image(
                prompt=prompt,
                session=session,
                family_id=trip.family_id,
                image_data=original,
                content_type=trip.original_content_type,
            )
        except Exception as exc:  # noqa: BLE001 — background must never raise
            logger.warning("travel generate failed for %s: %s", trip_id, exc)
            trip.ai_status = "failed"
            session.add(trip)
            await session.commit()
            return

        old_key = trip.original_key
        new_key = build_storage_key(
            trip.family_id, trip.id, "ai", ext_from_ct(img_ct)
        )
        await storage.put(new_key, img_bytes, img_ct)
        trip.original_key = new_key  # repurposed as the live image key
        trip.original_content_type = img_ct
        trip.original_width = None
        trip.original_height = None
        trip.ai_status = "ready"
        trip.updated_at = datetime.now(UTC)
        session.add(trip)
        await session.commit()

        if old_key and old_key != new_key:
            with contextlib.suppress(Exception):
                await storage.delete(old_key)


async def preview_hook(
    session: AsyncSession,
    ip: InstalledPlugin,
    viewer_id: UUID | None = None,
) -> PluginPreview:
    """Home card: 去过 N 城 · M 段 + a few recent cover thumbnails."""
    family_id = ip.family_id
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
    if not rows:
        return PluginPreview(
            primary="还没有旅行记录",
            secondary="点一下，钉下第一段",
            color_token="travel",
        )
    cities = {r.city_name for r in rows}
    covers = [image_url(family_id, r.id, v=_ver(r)) for r in rows[:4]]
    return PluginPreview(
        primary=f"去过 {len(cities)} 城",
        secondary=f"{len(rows)} 段旅行",
        color_token="travel",
        image_urls=covers,
    )


__all__ = [
    "DEFAULT_PROMPT",
    "TripRead",
    "build_prompt",
    "build_storage_key",
    "ext_from_ct",
    "image_url",
    "to_trip_read",
    "generate_for_trip",
    "preview_hook",
]
