"""Family business logic — creation, lookup, listing, switching.

Routes call into these functions; they handle transactions, joins, and
permission checks via `require_membership`.
"""

from __future__ import annotations

from uuid import UUID

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_admin, require_membership
from app.models.family import Family, FamilyCreate, FamilyUpdate
from app.models.membership import Membership
from app.models.user import User


async def create_family(
    session: AsyncSession,
    payload: FamilyCreate,
    creator: User,
) -> tuple[Family, Membership]:
    """Create a Family + creator's Owner Membership atomically.

    Also sets `creator.current_family_id` if it was unset, so a brand-new
    user lands inside their newly-created family.
    """
    family = Family.model_validate(payload)
    session.add(family)
    await session.flush()  # populate family.id without committing yet

    membership = Membership(
        user_id=creator.id,
        family_id=family.id,
        role="owner",
        display_name=creator.display_name,
        avatar_emoji=creator.avatar_emoji,
    )
    session.add(membership)

    if creator.current_family_id is None:
        creator.current_family_id = family.id
        session.add(creator)

    await session.commit()
    await session.refresh(family)
    await session.refresh(membership)
    return family, membership


async def get_family_view(
    session: AsyncSession,
    family_id: UUID,
    user: User,
) -> tuple[Family, Membership, int]:
    """Fetch a family the user is a member of, plus the viewer's role & count."""
    membership = await require_membership(session, user.id, family_id)
    family = await session.get(Family, family_id)
    if family is None:
        # Should not happen given membership exists, but be defensive.
        raise AppError(
            ErrorCode.FAMILY_NOT_FOUND,
            "家庭不存在",
            status_code=404,
        )
    member_count = await _count_active_members(session, family_id)
    return family, membership, member_count


async def update_family(
    session: AsyncSession,
    family_id: UUID,
    payload: FamilyUpdate,
    user: User,
) -> tuple[Family, Membership, int]:
    """Update a family's profile (name/slogan/emoji). Owner/Admin only."""
    membership = await require_membership(session, user.id, family_id)
    require_admin(membership)
    family = await session.get(Family, family_id)
    if family is None:
        # Membership exists, so this is defensive only.
        raise AppError(ErrorCode.FAMILY_NOT_FOUND, "家庭不存在", status_code=404)

    for key, value in payload.model_dump(exclude_unset=True).items():
        setattr(family, key, value)
    session.add(family)
    await session.commit()
    await session.refresh(family)

    member_count = await _count_active_members(session, family_id)
    return family, membership, member_count


async def list_user_families(
    session: AsyncSession,
    user: User,
) -> list[tuple[Family, Membership, int]]:
    """All active families the user belongs to, with viewer-side fields."""
    stmt = (
        select(Family, Membership)
        .join(Membership, Membership.family_id == Family.id)
        .where(
            Membership.user_id == user.id,
            Membership.status == "active",
        )
    )
    rows = (await session.execute(stmt)).all()
    if not rows:
        return []

    # One aggregate query to fetch counts for all families in scope.
    family_ids = [f.id for f, _ in rows]
    count_stmt = (
        select(Membership.family_id, func.count().label("cnt"))
        .where(
            Membership.family_id.in_(family_ids),
            Membership.status == "active",
        )
        .group_by(Membership.family_id)
    )
    counts: dict[UUID, int] = {fid: cnt for fid, cnt in (await session.execute(count_stmt)).all()}
    return [(f, m, counts.get(f.id, 0)) for f, m in rows]


async def switch_current_family(
    session: AsyncSession,
    user: User,
    family_id: UUID,
) -> tuple[Family, Membership, int]:
    """Set `user.current_family_id` to a family the user is a member of."""
    family, membership, count = await get_family_view(session, family_id, user)
    if user.current_family_id != family_id:
        user.current_family_id = family_id
        session.add(user)
        await session.commit()
    return family, membership, count


async def list_members(
    session: AsyncSession,
    family_id: UUID,
    requester: User,
) -> list[Membership]:
    """List all memberships in a family. Requester must be a member."""
    await require_membership(session, requester.id, family_id)
    stmt = (
        select(Membership).where(Membership.family_id == family_id).order_by(Membership.joined_at)
    )
    return list((await session.execute(stmt)).scalars().all())


async def _count_active_members(session: AsyncSession, family_id: UUID) -> int:
    stmt = (
        select(func.count())
        .select_from(Membership)
        .where(
            Membership.family_id == family_id,
            Membership.status == "active",
        )
    )
    return int((await session.execute(stmt)).scalar_one())
