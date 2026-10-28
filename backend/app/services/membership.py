"""Shared family-member display helpers.

Plugins that show "who did this" (memory authors, accounting recorders, …) all
need the same thing: a member's per-family display name + emoji, plus whether
they have a real uploaded avatar (and its version) so the client can render the
photo instead of the emoji. Centralized here so each plugin doesn't re-implement
the Membership⋈User join and the avatar-URL composition.
"""

import hashlib
from typing import NamedTuple
from uuid import UUID

from sqlalchemy import text
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


ANONYMOUS_MEMBER = MemberInfo(name="匿名用户", emoji="👤", avatar_version=0, has_avatar=False)


async def lock_family_memberships(session: AsyncSession, family_id: UUID) -> None:
    """成员退出、加入、角色变更和注销共享事务锁，不阻塞家庭内容的外键引用。"""
    digest = hashlib.sha256(b"family-memberships:" + family_id.bytes).digest()
    lock_key = int.from_bytes(digest[:8], "big", signed=True)
    await session.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": lock_key})


def historical_member_info(
    members: dict[UUID, MemberInfo], user_id: UUID | None
) -> MemberInfo | None:
    """历史作者已退出或注销时统一匿名展示；没有指派对象仍保持空值。

    保留原用户外键以维持私密内容权限、幂等和历史归属，不通过外键暴露原昵称或头像。
    """
    return members.get(user_id, ANONYMOUS_MEMBER) if user_id is not None else None


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
        .where(
            Membership.family_id == family_id,
            Membership.status == "active",
            User.deleted_at.is_(None),
        )
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
