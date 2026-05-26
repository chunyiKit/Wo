"""Member endpoints: list, leave, change role, transfer ownership."""

from uuid import UUID

from fastapi import APIRouter
from pydantic import BaseModel

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.response import ApiResponse, ok
from app.models.membership import MembershipRead, Role
from app.services import family as family_service

router = APIRouter(prefix="/families", tags=["members"])


class MemberRoleUpdate(BaseModel):
    role: Role


class OwnershipTransfer(BaseModel):
    new_owner_id: UUID


@router.get(
    "/{family_id}/members",
    response_model=ApiResponse[list[MembershipRead]],
)
async def list_family_members(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[MembershipRead]]:
    members = await family_service.list_members(session, family_id, current_user)
    return ok([MembershipRead.model_validate(m, from_attributes=True) for m in members])


@router.delete(
    "/{family_id}/members/me",
    response_model=ApiResponse[None],
)
async def leave_family_endpoint(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[None]:
    """Leave a family (remove your own membership). Owner cannot leave."""
    await family_service.leave_family(session, family_id, current_user)
    return ok(None)


@router.patch(
    "/{family_id}/members/{user_id}",
    response_model=ApiResponse[MembershipRead],
)
async def update_member_role_endpoint(
    family_id: UUID,
    user_id: UUID,
    payload: MemberRoleUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[MembershipRead]:
    """Change a member's role. Owner/Admin only; cannot target the owner."""
    membership = await family_service.update_member_role(
        session, family_id, user_id, payload.role, current_user
    )
    return ok(MembershipRead.model_validate(membership, from_attributes=True))


@router.post(
    "/{family_id}/transfer-ownership",
    response_model=ApiResponse[None],
)
async def transfer_ownership_endpoint(
    family_id: UUID,
    payload: OwnershipTransfer,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[None]:
    """Transfer ownership to another active member. Current owner only."""
    await family_service.transfer_ownership(
        session, family_id, payload.new_owner_id, current_user
    )
    return ok(None)
