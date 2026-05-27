"""Member endpoints: list, leave, change role, transfer ownership."""

from uuid import UUID

from fastapi import APIRouter
from pydantic import BaseModel
from starlette.responses import Response

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.core.storage import storage
from app.models.membership import MembershipRead, Role
from app.models.user import User
from app.services import family as family_service
from app.services.membership import author_avatar_url, member_info_map

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
    # Inject each member's real-avatar URL (lives on User, not Membership) so the
    # member list can show photos, falling back to emoji when unset.
    info = await member_info_map(session, family_id)
    reads = []
    for m in members:
        read = MembershipRead.model_validate(m, from_attributes=True)
        reads.append(
            read.model_copy(
                update={
                    "avatar_url": author_avatar_url(
                        family_id, m.user_id, info.get(m.user_id)
                    )
                }
            )
        )
    return ok(reads)


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


@router.get("/{family_id}/members/{user_id}/avatar")
async def get_member_avatar_raw(
    family_id: UUID,
    user_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    """返回某个家庭成员的头像原始字节（非信封）。

    家庭内成员互相可见：调用者须是该家庭成员，目标用户也须是同一家庭的成员
    （`require_membership` 对非成员一律 404，既校验权限又不泄露存在性）。URL 带
    `?v=` 版本号，可长期缓存。未设头像返回 404，客户端回退到 emoji。
    """
    await require_membership(session, current_user.id, family_id)
    await require_membership(session, user_id, family_id)

    user = await session.get(User, user_id)
    if user is None or user.avatar_storage_key is None:
        raise AppError(ErrorCode.NOT_FOUND, "尚未设置头像", status_code=404)
    try:
        data = await storage.get(user.avatar_storage_key)
    except FileNotFoundError as exc:
        raise AppError(ErrorCode.INTERNAL, "头像文件丢失", status_code=500) from exc
    return Response(
        content=data,
        media_type=user.avatar_content_type or "application/octet-stream",
        headers={"Cache-Control": "public, max-age=31536000, immutable"},
    )


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
