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
from app.core.permissions import require_admin, require_membership, require_role
from app.models.family import Family, FamilyCreate, FamilyUpdate
from app.models.membership import INVITABLE_ROLES, Membership
from app.models.user import User
from app.services import notification as notification_service

_ROLE_LABELS: dict[str, str] = {
    "owner": "主理人",
    "admin": "管理员",
    "member": "家人",
    "child": "孩子",
    "pet": "宠物",
}


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


async def leave_family(
    session: AsyncSession,
    family_id: UUID,
    user: User,
) -> None:
    """Remove the user's own membership from a family.

    The Owner cannot leave directly — ownership must first be transferred or
    the family dissolved (a separate flow). If the family being left is the
    user's current family, switch to another joined family (oldest first) or
    clear it. Remaining members are notified. Atomic.
    """
    membership = await require_membership(session, user.id, family_id)
    if membership.role == "owner":
        raise AppError(
            ErrorCode.FORBIDDEN,
            "主理人需先转移身份或解散家庭，无法直接离开",
            status_code=403,
            details={"your_role": membership.role},
        )

    family = await session.get(Family, family_id)
    await session.delete(membership)
    await session.flush()  # so the count/recipient queries below exclude us

    # If we were standing in this family, move to another joined one (or none).
    if user.current_family_id == family_id:
        next_stmt = (
            select(Membership.family_id)
            .where(
                Membership.user_id == user.id,
                Membership.status == "active",
            )
            .order_by(Membership.joined_at)
            .limit(1)
        )
        user.current_family_id = (await session.execute(next_stmt)).scalars().first()
        session.add(user)

    if family is not None:
        await notification_service.notify_member_left(
            session, family=family, leaving_user=user
        )

    await session.commit()


async def _active_membership(
    session: AsyncSession,
    user_id: UUID,
    family_id: UUID,
) -> Membership | None:
    stmt = select(Membership).where(
        Membership.user_id == user_id,
        Membership.family_id == family_id,
        Membership.status == "active",
    )
    return (await session.execute(stmt)).scalar_one_or_none()


async def update_member_role(
    session: AsyncSession,
    family_id: UUID,
    target_user_id: UUID,
    new_role: str,
    requester: User,
) -> Membership:
    """Change another member's role. Owner/Admin only.

    The owner's role can't be changed here — ownership moves via
    `transfer_ownership`. Target role is limited to the invitable set, so no
    one can be promoted to owner through this path.
    """
    requester_m = await require_membership(session, requester.id, family_id)
    require_admin(requester_m)

    if new_role not in INVITABLE_ROLES:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            f"非法 role：{new_role}",
            status_code=422,
            details={"allowed": list(INVITABLE_ROLES)},
        )

    target = await _active_membership(session, target_user_id, family_id)
    if target is None:
        raise AppError(ErrorCode.NOT_FOUND, "成员不存在", status_code=404)
    if target.role == "owner":
        raise AppError(
            ErrorCode.FORBIDDEN,
            "主理人身份需通过转让变更",
            status_code=403,
        )

    if target.role != new_role:
        target.role = new_role
        session.add(target)
        family = await session.get(Family, family_id)
        if family is not None:
            await notification_service.notify_role_changed(
                session,
                family=family,
                target_user_id=target_user_id,
                role_label=_ROLE_LABELS.get(new_role, new_role),
            )
        await session.commit()
        await session.refresh(target)
    return target


async def transfer_ownership(
    session: AsyncSession,
    family_id: UUID,
    new_owner_user_id: UUID,
    requester: User,
) -> None:
    """Hand ownership to another active member. Only the current owner may do
    this. The previous owner is demoted to admin. Atomic."""
    requester_m = await require_membership(session, requester.id, family_id)
    require_role(requester_m, "owner")

    if new_owner_user_id == requester.id:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            "不能把主理人转让给自己",
            status_code=422,
        )

    target = await _active_membership(session, new_owner_user_id, family_id)
    if target is None:
        raise AppError(ErrorCode.NOT_FOUND, "目标成员不存在", status_code=404)

    target.role = "owner"
    requester_m.role = "admin"
    session.add(target)
    session.add(requester_m)

    family = await session.get(Family, family_id)
    if family is not None:
        new_owner = await session.get(User, new_owner_user_id)
        if new_owner is not None:
            await notification_service.notify_ownership_transferred(
                session,
                family=family,
                new_owner=new_owner,
                previous_owner=requester,
            )

    await session.commit()


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
