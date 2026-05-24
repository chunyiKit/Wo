"""Role-based access helpers.

`require_membership` is the cornerstone of data isolation (contract §8): every
family-scoped endpoint MUST call it. Returning the Membership object also
saves a second query when the route needs the viewer's role.
"""

from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.errors import AppError, ErrorCode
from app.models.membership import ADMIN_OR_OWNER, Membership


async def require_membership(
    session: AsyncSession,
    user_id: UUID,
    family_id: UUID,
) -> Membership:
    """Verify the user is an active member of the family.

    Returns 404 `FAMILY_NOT_FOUND` (not 403) whether the family doesn't exist
    or the user simply isn't a member — this hides family existence from
    non-members, per the data-isolation principle.
    """
    stmt = select(Membership).where(
        Membership.user_id == user_id,
        Membership.family_id == family_id,
        Membership.status == "active",
    )
    result = await session.execute(stmt)
    membership = result.scalar_one_or_none()
    if membership is None:
        raise AppError(
            ErrorCode.FAMILY_NOT_FOUND,
            "家庭不存在或你不是该家庭成员",
            status_code=404,
            details={"family_id": str(family_id)},
        )
    return membership


def require_role(membership: Membership, *allowed: str) -> None:
    if membership.role not in allowed:
        raise AppError(
            ErrorCode.FORBIDDEN,
            f"该操作需要 {' / '.join(allowed)} 权限",
            status_code=403,
            details={"your_role": membership.role, "required": list(allowed)},
        )


def require_admin(membership: Membership) -> None:
    """Owner or Admin allowed."""
    require_role(membership, *ADMIN_OR_OWNER)
