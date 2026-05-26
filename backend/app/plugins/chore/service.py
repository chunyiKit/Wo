"""Chore business logic — assignee display injection + viewer-aware preview."""

from uuid import UUID

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.membership import Membership
from app.models.plugin import InstalledPlugin
from app.plugins.chore.models import Chore, ChoreRead
from app.plugins.registry import PluginPreview


async def member_map(session: AsyncSession, family_id: UUID) -> dict[UUID, tuple[str, str]]:
    """Map user_id → (display_name, avatar_emoji) for a family's members."""
    stmt = select(Membership).where(Membership.family_id == family_id)
    rows = (await session.execute(stmt)).scalars().all()
    return {m.user_id: (m.display_name, m.avatar_emoji) for m in rows}


def build_read(row: Chore, members: dict[UUID, tuple[str, str]]) -> ChoreRead:
    """Serialize a row, injecting assignee display info (immutable copy)."""
    read = ChoreRead.model_validate(row, from_attributes=True)
    name, emoji = (None, None)
    if row.assigned_to is not None and row.assigned_to in members:
        name, emoji = members[row.assigned_to]
    return read.model_copy(update={"assignee_name": name, "assignee_emoji": emoji})


async def _open_count_for(session: AsyncSession, family_id: UUID, user_id: UUID) -> int:
    """How many not-done chores are assigned to this user in this family."""
    stmt = (
        select(func.count())
        .select_from(Chore)
        .where(
            Chore.family_id == family_id,
            Chore.assigned_to == user_id,
            Chore.done.is_(False),
        )
    )
    return int((await session.execute(stmt)).scalar_one())


async def _family_open_count(session: AsyncSession, family_id: UUID) -> int:
    """How many not-done chores exist in the family (any assignee)."""
    stmt = (
        select(func.count())
        .select_from(Chore)
        .where(Chore.family_id == family_id, Chore.done.is_(False))
    )
    return int((await session.execute(stmt)).scalar_one())


async def preview_hook(
    session: AsyncSession, ip: InstalledPlugin, viewer_id: UUID | None = None
) -> PluginPreview:
    """Render the home card: how many chores *the viewer* still owes.

    Falls back to the family's total open chores when there's no viewer (e.g. a
    server-side render without a user) so the card always says something useful.
    """
    if viewer_id is not None:
        mine = await _open_count_for(session, ip.family_id, viewer_id)
        if mine > 0:
            return PluginPreview(
                primary=f"{mine} 件家务待做",
                secondary="该你出手啦",
                color_token="chore",
                secondary_tone="warning",
                badge=str(mine),
                emoji="🧹",
            )

    total_open = await _family_open_count(session, ip.family_id)
    if total_open == 0:
        return PluginPreview(
            primary="家务都做完啦",
            secondary="干净又整齐 ✨",
            color_token="chore",
            emoji="🧹",
        )
    return PluginPreview(
        primary="你没有待办家务",
        secondary=f"家里还有 {total_open} 件",
        color_token="chore",
        emoji="🧹",
    )
