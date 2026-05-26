"""Recipe business logic — author display injection + home preview hook."""

from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.membership import Membership
from app.models.plugin import InstalledPlugin
from app.plugins.recipe.models import (
    DEFAULT_TAGS,
    Recipe,
    RecipeRead,
    RecipeTag,
)
from app.plugins.registry import PluginPreview


async def member_map(
    session: AsyncSession, family_id: UUID
) -> dict[UUID, tuple[str, str]]:
    """Map user_id → (display_name, avatar_emoji) for a family's members."""
    stmt = select(Membership).where(Membership.family_id == family_id)
    rows = (await session.execute(stmt)).scalars().all()
    return {m.user_id: (m.display_name, m.avatar_emoji) for m in rows}


def build_cover_storage_key(family_id: UUID, recipe_id: UUID, ext: str) -> str:
    """Namespace recipe covers by family for easy backup/cleanup boundaries."""
    return f"recipes/{family_id}/{recipe_id}.{ext}"


def build_cover_url(family_id: UUID, recipe_id: UUID, version: int) -> str:
    """Relative raw-bytes URL with a `?v=` cache-buster keyed on the version."""
    return (
        f"/api/v1/families/{family_id}/plugins/recipe/recipes/{recipe_id}"
        f"/cover?v={version}"
    )


def build_read(
    row: Recipe, members: dict[UUID, tuple[str, str]]
) -> RecipeRead:
    """Serialize a row, injecting author display info + cover URL (immutable copy)."""
    read = RecipeRead.model_validate(row, from_attributes=True)
    name, emoji = (None, None)
    if row.created_by is not None and row.created_by in members:
        name, emoji = members[row.created_by]
    cover_url = (
        build_cover_url(row.family_id, row.id, row.cover_version)
        if row.cover_storage_key is not None
        else None
    )
    return read.model_copy(
        update={
            "creator_name": name,
            "creator_emoji": emoji,
            "cover_url": cover_url,
        }
    )


async def _query_tags(session: AsyncSession, family_id: UUID) -> list[str]:
    """Raw tag names, oldest first. No seeding."""
    stmt = (
        select(RecipeTag)
        .where(RecipeTag.family_id == family_id)
        .order_by(RecipeTag.created_at)
    )
    return [r.name for r in (await session.execute(stmt)).scalars().all()]


async def _mark_seeded(session: AsyncSession, family_id: UUID) -> None:
    """Flag the recipe install so we never re-seed (deleting all stays empty).

    Stored on InstalledPlugin.config rather than a new column — recipe is
    single-instance, so there's exactly one row per family. If the plugin isn't
    installed (tags hit without a card) there's nowhere to mark; we skip.
    """
    ip = (
        await session.execute(
            select(InstalledPlugin).where(
                InstalledPlugin.family_id == family_id,
                InstalledPlugin.plugin_id == "recipe",
            )
        )
    ).scalars().first()
    if ip is not None and not ip.config.get("tags_seeded"):
        # Reassign (not mutate-in-place) so SQLAlchemy detects the JSONB change.
        ip.config = {**ip.config, "tags_seeded": True}
        session.add(ip)
        await session.commit()


async def list_tags(session: AsyncSession, family_id: UUID) -> list[str]:
    """Family's tag palette, oldest first.

    The first time a family reads an empty list we seed the recommended starter
    tags (and mark it seeded). After that the list is fully user-managed —
    deleting down to empty stays empty.
    """
    rows = await _query_tags(session, family_id)
    if rows:
        return rows

    ip = (
        await session.execute(
            select(InstalledPlugin).where(
                InstalledPlugin.family_id == family_id,
                InstalledPlugin.plugin_id == "recipe",
            )
        )
    ).scalars().first()
    if ip is not None and ip.config.get("tags_seeded"):
        return []  # Emptied on purpose — respect it.

    session.add_all(
        [RecipeTag(family_id=family_id, name=name) for name in DEFAULT_TAGS]
    )
    await session.commit()
    await _mark_seeded(session, family_id)
    return list(DEFAULT_TAGS)


async def add_tag(session: AsyncSession, family_id: UUID, name: str) -> list[str]:
    """Add a tag (idempotent, trimmed). Returns the updated list."""
    name = name.strip()
    if name:
        existing = (
            await session.execute(
                select(RecipeTag).where(
                    RecipeTag.family_id == family_id, RecipeTag.name == name
                )
            )
        ).scalar_one_or_none()
        if existing is None:
            session.add(RecipeTag(family_id=family_id, name=name))
            await session.commit()
    # Adding counts as curating the list → don't let a later empty re-seed.
    await _mark_seeded(session, family_id)
    return await _query_tags(session, family_id)


async def delete_tag(session: AsyncSession, family_id: UUID, name: str) -> list[str]:
    """Remove a tag from the palette. Existing recipes keep their category."""
    row = (
        await session.execute(
            select(RecipeTag).where(
                RecipeTag.family_id == family_id, RecipeTag.name == name
            )
        )
    ).scalar_one_or_none()
    if row is not None:
        await session.delete(row)
        await session.commit()
    await _mark_seeded(session, family_id)  # deleting down to empty must stick
    return await _query_tags(session, family_id)


async def preview_hook(
    session: AsyncSession, ip: InstalledPlugin, _viewer_id: UUID | None = None
) -> PluginPreview:
    """Render the home card: newest dish name + total count."""
    stmt = (
        select(Recipe)
        .where(Recipe.family_id == ip.family_id)
        .order_by(Recipe.created_at.desc())
    )
    rows = list((await session.execute(stmt)).scalars().all())

    if not rows:
        return PluginPreview(
            primary="还没有菜谱",
            secondary="点击添加第一道菜",
            color_token="accent",
            emoji="🍳",
        )

    latest = rows[0]
    return PluginPreview(
        primary=latest.name,
        secondary=f"共 {len(rows)} 道菜",
        color_token="accent",
        emoji=latest.emoji,
    )
