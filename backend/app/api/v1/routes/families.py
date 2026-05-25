"""Family CRUD-lite endpoints — create, fetch, switch."""

from uuid import UUID

from fastapi import APIRouter

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.response import ApiResponse, ok
from app.models.family import FamilyCreate, FamilyRead, FamilyUpdate
from app.services import family as family_service

router = APIRouter(prefix="/families", tags=["families"])


@router.post("", response_model=ApiResponse[FamilyRead], status_code=201)
async def create_family(
    payload: FamilyCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[FamilyRead]:
    family, membership = await family_service.create_family(session, payload, current_user)
    # Freshly-created family has exactly one member (the creator/owner).
    return ok(FamilyRead.from_components(family, membership, member_count=1))


@router.get("/{family_id}", response_model=ApiResponse[FamilyRead])
async def get_family(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[FamilyRead]:
    family, membership, count = await family_service.get_family_view(
        session, family_id, current_user
    )
    return ok(FamilyRead.from_components(family, membership, count))


@router.patch("/{family_id}", response_model=ApiResponse[FamilyRead])
async def update_family(
    family_id: UUID,
    payload: FamilyUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[FamilyRead]:
    family, membership, count = await family_service.update_family(
        session, family_id, payload, current_user
    )
    return ok(FamilyRead.from_components(family, membership, count))


@router.post("/{family_id}/switch", response_model=ApiResponse[FamilyRead])
async def switch_family(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[FamilyRead]:
    family, membership, count = await family_service.switch_current_family(
        session, current_user, family_id
    )
    return ok(FamilyRead.from_components(family, membership, count))
