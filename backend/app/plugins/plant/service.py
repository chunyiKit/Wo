"""Plant journal plugin business logic — read serialization, storage keys,
care-cycle math, and the home-card preview.

Plant-specific reasoning lives here (and in `ai.py`), never in the shared
`app.services.weather` / `app.services.ai` modules.
"""

from __future__ import annotations

from datetime import date
from uuid import UUID

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.plugin import InstalledPlugin
from app.plugins.plant.models import (
    Plant,
    PlantLog,
    PlantLogRead,
    PlantRead,
)
from app.plugins.registry import PluginPreview

_PLUGIN_COLOR = "plant"
_PLUGIN_EMOJI = "🌿"


def build_storage_key(
    family_id: UUID, plant_id: UUID, log_id: UUID, ext: str, index: int = 0
) -> str:
    """Blob key for a care-log photo (one log may have several). Durable history
    record (see design D4)."""
    return f"plant/{family_id}/{plant_id}/{log_id}_{index}.{ext}"


def build_plant_read(plant: Plant) -> PlantRead:
    """Serialize a plant, injecting the host-relative cover URL (with `?v=`
    cache-buster). None until a cover is saved."""
    read = PlantRead.model_validate(plant, from_attributes=True)
    cover_url = None
    if plant.cover_storage_key:
        cover_url = (
            f"/api/v1/families/{plant.family_id}/plugins/plant/plants/"
            f"{plant.id}/cover?v={plant.cover_version}"
        )
    return read.model_copy(update={"cover_url": cover_url})


def build_log_read(log: PlantLog) -> PlantLogRead:
    """Serialize a care log, injecting host-relative photo URLs.

    New logs store all photos in `log.photos` → one indexed URL each. Legacy
    logs (single `photo_storage_key`, no `photos`) → the old /photo URL.
    """
    base = (
        f"/api/v1/families/{log.family_id}/plugins/plant/plants/"
        f"{log.plant_id}/logs/{log.id}"
    )
    v = log.photo_version or 1
    photo_urls: list[str] = []
    if log.photos:
        photo_urls = [f"{base}/photos/{i}?v={v}" for i in range(len(log.photos))]
    elif log.photo_storage_key:
        photo_urls = [f"{base}/photo?v={v}"]
    return read_with_photos(log, photo_urls)


def read_with_photos(log: PlantLog, photo_urls: list[str]) -> PlantLogRead:
    read = PlantLogRead.model_validate(log, from_attributes=True)
    return read.model_copy(
        update={
            "photo_url": photo_urls[0] if photo_urls else None,
            "photo_urls": photo_urls,
        }
    )


def arm_due_dates(plant: Plant, *, today: date) -> None:
    """Recompute `next_*_due` from the current intervals.

    Setting an interval arms the reminder (next due = today + interval). Clearing
    it (None) disarms — the reminder loop skips plants with a null due date.
    Mutates `plant` in place (caller commits).
    """
    if plant.water_interval_days:
        plant.next_water_due = date.fromordinal(
            today.toordinal() + plant.water_interval_days
        )
    else:
        plant.next_water_due = None
    if plant.fert_interval_days:
        plant.next_fert_due = date.fromordinal(
            today.toordinal() + plant.fert_interval_days
        )
    else:
        plant.next_fert_due = None


async def preview_hook(
    session: AsyncSession,
    ip: InstalledPlugin,
    viewer_id: object = None,
) -> PluginPreview:
    """Home card: how many plants, and the nearest upcoming care task.

    - 0 plants → 「还没有植物」 + 「添加一株」
    - has plants, none due soon → 「N 株植物」 + 「都照料好啦」
    - a care task due → 「该给『X』浇水/施肥」 (overdue → danger tone)
    """
    family_id = ip.family_id
    total = int(
        (
            await session.execute(
                select(func.count())
                .select_from(Plant)
                .where(Plant.family_id == family_id)
            )
        ).scalar_one()
    )
    if total == 0:
        return PluginPreview(
            primary="还没有植物",
            secondary="添加一株",
            color_token=_PLUGIN_COLOR,
            emoji=_PLUGIN_EMOJI,
        )

    # Nearest upcoming/overdue water or fert task across the family's plants.
    rows = list(
        (
            await session.execute(
                select(Plant).where(Plant.family_id == family_id)
            )
        ).scalars().all()
    )
    best: tuple[date, str, str, str] | None = None  # (due, kind, name, emoji)
    for p in rows:
        for due, kind in ((p.next_water_due, "浇水"), (p.next_fert_due, "施肥")):
            if due is None:
                continue
            if best is None or due < best[0]:
                best = (due, kind, p.name, p.emoji)

    if best is None:
        return PluginPreview(
            primary=f"{total} 株植物",
            secondary="都照料好啦",
            color_token=_PLUGIN_COLOR,
            emoji=_PLUGIN_EMOJI,
        )

    due, kind, name, emoji = best
    return PluginPreview(
        primary=f"该给『{name}』{kind}",
        secondary=f"共 {total} 株",
        color_token=_PLUGIN_COLOR,
        emoji=emoji or _PLUGIN_EMOJI,
    )


__all__ = [
    "build_storage_key",
    "build_plant_read",
    "build_log_read",
    "arm_due_dates",
    "preview_hook",
]
