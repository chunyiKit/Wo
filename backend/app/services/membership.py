"""Shared family-member display helpers.

Plugins that show "who did this" (memory authors, accounting recorders, …) all
need the same thing: a member's per-family display name + emoji, plus whether
they have a real uploaded avatar (and its version) so the client can render the
photo instead of the emoji. Centralized here so each plugin doesn't re-implement
the Membership⋈User join and the avatar-URL composition.
"""

from typing import NamedTuple
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.membership import Membership
from app.models.user import User
from app.services.user import build_member_avatar_url


class MemberInfo(NamedTuple):
    """A family member's display info for composing author/recorder lines."""

    name: str
    emoji: str
    avatar_version: int
    has_avatar: bool


async def member_info_map(
    session: AsyncSession, family_id: UUID
) -> dict[UUID, MemberInfo]:
    """Map user_id → MemberInfo for a family's members.

    Joins User so we also know whether each member uploaded a real avatar (and
    its version), not just the per-family display name + emoji.
    """
    stmt = (
        select(Membership, User)
        .join(User, Membership.user_id == User.id)
        .where(Membership.family_id == family_id)
    )
    rows = (await session.execute(stmt)).all()
    return {
        m.user_id: MemberInfo(
            name=m.display_name,
            emoji=m.avatar_emoji,
            avatar_version=u.avatar_version,
            has_avatar=u.avatar_storage_key is not None,
        )
        for (m, u) in rows
    }


def author_avatar_url(
    family_id: UUID, user_id: UUID | None, info: MemberInfo | None
) -> str | None:
    """Member-avatar URL when the member has a real uploaded photo, else None
    (the client falls back to the emoji)."""
    if user_id is None or info is None or not info.has_avatar:
        return None
    return build_member_avatar_url(family_id, user_id, info.avatar_version)
