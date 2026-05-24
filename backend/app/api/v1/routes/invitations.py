"""Invitation endpoints.

Routes split across two prefixes:
- `POST /families/{id}/invitations` — generate (Admin+ only)
- `GET  /invitations/{code}/preview` — public preview (no auth needed in P5)
- `POST /invitations/{code}/accept`  — join the family

Both routers are registered in `app.api.v1.router`.
"""

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.errors import AppError, ErrorCode
from app.core.response import ApiResponse, ok
from app.models.family import Family, FamilyRead
from app.models.membership import Role
from app.services import family as family_service
from app.services import invitation as invitation_service

# Two routers because the URL hierarchies differ.
families_router = APIRouter(prefix="/families", tags=["invitations"])
public_router = APIRouter(prefix="/invitations", tags=["invitations"])


# ---- POST /families/{family_id}/invitations -------------------------------


class InvitationCreate(BaseModel):
    role: Role = "member"
    ttl_seconds: int = Field(default=7 * 24 * 3600, gt=0)
    channel: str = "link"


class InvitationCreateResponse(BaseModel):
    code: str  # display form, e.g. "WO-W4M9-P2KX"
    link: str
    qr_payload: str
    expires_at: datetime


@families_router.post(
    "/{family_id}/invitations",
    response_model=ApiResponse[InvitationCreateResponse],
    status_code=201,
)
async def create_invitation_endpoint(
    family_id: UUID,
    payload: InvitationCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[InvitationCreateResponse]:
    invitation = await invitation_service.create_invitation(
        session=session,
        inviter=current_user,
        family_id=family_id,
        role=payload.role,
        ttl_seconds=payload.ttl_seconds,
        channel=payload.channel,
    )
    return ok(
        InvitationCreateResponse(
            code=invitation_service.format_code_for_display(invitation.code),
            link=invitation_service.build_link(invitation.code),
            qr_payload=invitation_service.build_qr_payload(invitation.code),
            expires_at=invitation.expires_at,
        )
    )


# ---- GET /invitations/{code}/preview --------------------------------------


class InviterPreview(BaseModel):
    display_name: str
    avatar_emoji: str


class FamilyPreview(BaseModel):
    id: UUID
    name: str
    emoji: str
    member_count: int


class InvitationPreviewResponse(BaseModel):
    family: FamilyPreview
    inviter: InviterPreview | None
    role: Role
    expires_at: datetime


async def _family_preview(session: AsyncSession, family: Family) -> FamilyPreview:
    count = await family_service._count_active_members(session, family.id)
    return FamilyPreview(id=family.id, name=family.name, emoji=family.emoji, member_count=count)


@public_router.get(
    "/{code}/preview",
    response_model=ApiResponse[InvitationPreviewResponse],
)
async def preview_invitation(
    code: str,
    session: SessionDep,
) -> ApiResponse[InvitationPreviewResponse]:
    invitation = await invitation_service.get_usable_invitation(session, code)

    family = await session.get(Family, invitation.family_id)
    if family is None:
        raise AppError(
            ErrorCode.FAMILY_NOT_FOUND,
            "邀请所属的家庭已不存在",
            status_code=404,
        )

    inviter_preview: InviterPreview | None = None
    if invitation.inviter_id is not None:
        from app.models.user import User  # local import avoids any cycle

        inviter = await session.get(User, invitation.inviter_id)
        if inviter is not None:
            inviter_preview = InviterPreview(
                display_name=inviter.display_name,
                avatar_emoji=inviter.avatar_emoji,
            )

    return ok(
        InvitationPreviewResponse(
            family=await _family_preview(session, family),
            inviter=inviter_preview,
            role=invitation.role,  # type: ignore[arg-type]
            expires_at=invitation.expires_at,
        )
    )


# ---- POST /invitations/{code}/accept --------------------------------------


@public_router.post(
    "/{code}/accept",
    response_model=ApiResponse[FamilyRead],
)
async def accept_invitation_endpoint(
    code: str,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[FamilyRead]:
    invitation = await invitation_service.get_usable_invitation(session, code)
    family, membership = await invitation_service.accept_invitation(
        session, invitation, current_user
    )
    member_count = await family_service._count_active_members(session, family.id)
    return ok(FamilyRead.from_components(family, membership, member_count))
