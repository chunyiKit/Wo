"""Current-user profile updates.

`update_me` changes the user's global profile (currently just `display_name`).
Each Membership carries its own per-family `display_name` (contract §5.3): the
idea is a user can appear as "爸爸" in one family and "老陈" in another. But
there is no UI/endpoint to set a per-family alias yet, so a membership's name is
just a snapshot of the global name taken at join time — and goes stale when the
global name later changes (e.g. accounting records show the recorder via the
membership name). Until per-family aliasing actually ships, we treat the global
name as the single source of truth and propagate a rename to *all* of the
user's memberships. This also self-heals rows that diverged before this fix.

NOTE: when per-family alias editing is added, this should become conditional
(only sync memberships the user hasn't customized).
"""

from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.membership import Membership
from app.models.user import User, UserUpdate


def build_avatar_storage_key(user_id: UUID, ext: str) -> str:
    """头像按用户命名空间存放，便于备份/清理。"""
    return f"avatars/{user_id}.{ext}"


async def update_me(session: AsyncSession, user: User, payload: UserUpdate) -> User:
    """Apply the provided fields to `user`, syncing membership display names."""
    data = payload.model_dump(exclude_unset=True)

    for key, value in data.items():
        setattr(user, key, value)
    session.add(user)

    # Sync per-membership names to the new global name. Compare per row (not
    # against the user's old name) so re-saving the *same* nickname still heals
    # memberships that already diverged before this sync existed.
    new_display_name = data.get("display_name")
    if new_display_name is not None:
        stmt = select(Membership).where(
            Membership.user_id == user.id,
            Membership.display_name != new_display_name,
        )
        for membership in (await session.execute(stmt)).scalars().all():
            membership.display_name = new_display_name
            session.add(membership)

    await session.commit()
    await session.refresh(user)
    return user
