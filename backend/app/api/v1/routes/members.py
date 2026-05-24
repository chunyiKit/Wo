"""Member list endpoint."""

from uuid import UUID

from fastapi import APIRouter

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.response import ApiResponse, ok
from app.models.membership import MembershipRead
from app.services import family as family_service

router = APIRouter(prefix="/families", tags=["members"])


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
