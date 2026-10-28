"""Headerless media URLs — the mini program's escape hatch from `Authorization`.

Every existing raw-bytes endpoint (`/me/avatar`, `.../members/{id}/avatar`,
`.../media/{id}/raw`) requires a bearer token, either because it checks
membership or because it 302s to a *private* COS object. The WeChat mini
program's `<image>` component loads a URL with no way to attach a header, so
those endpoints render as empty boxes there — the request 401s (or the redirect
target is private) and the component silently gives up.

These endpoints instead hand back a presigned COS URL: a plain https link that
carries its own short-lived signature. No header, no backend hop for the bytes.

They are **not** a general-purpose URL minting service. Each one re-runs the
exact authorization its `/raw` counterpart does, so the readable surface is
unchanged — only the transport differs. `expires_at` lets the client cache and
refresh before the link goes cold.
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID

from fastapi import APIRouter
from sqlmodel import SQLModel

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.core.storage import PresignableStorage, storage
from app.models.user import User

router = APIRouter(tags=["media-url"])

# Same lifetime the /raw redirects use. Avatars are cached by `?v=` version, but
# the *signed* URL is what ages out — an hour keeps a browsing session working.
AVATAR_URL_TTL_SECONDS = 3600


class DirectUrlRead(SQLModel):
    url: str
    # ISO-8601, UTC. The URL dies at this instant; refresh before then.
    expires_at: datetime


def _no_direct_url() -> AppError:
    """Local-disk deployments can't presign; say so instead of returning a URL
    that would 401 the moment `<image>` requested it."""
    return AppError(
        ErrorCode.STORAGE_NO_DIRECT_URL,
        "当前存储后端不支持直链，请改用 /raw 端点",
        status_code=501,
    )


async def _presign(key: str) -> DirectUrlRead:
    if not isinstance(storage, PresignableStorage):
        raise _no_direct_url()
    url = await storage.presigned_get_url(key, ttl_seconds=AVATAR_URL_TTL_SECONDS)
    expires_at = datetime.now(UTC) + timedelta(seconds=AVATAR_URL_TTL_SECONDS)
    return DirectUrlRead(url=url, expires_at=expires_at)


@router.get("/me/avatar-url", response_model=ApiResponse[DirectUrlRead])
async def my_avatar_url(
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[DirectUrlRead]:
    """Presigned URL for your own avatar.

    404 when you haven't uploaded one — the client then falls back to
    `avatar_emoji`, exactly as it does for `/me/avatar`.
    """
    if current_user.avatar_storage_key is None:
        raise AppError(ErrorCode.NOT_FOUND, "尚未设置头像", status_code=404)
    return ok(await _presign(current_user.avatar_storage_key))


@router.get(
    "/families/{family_id}/members/{user_id}/avatar-url",
    response_model=ApiResponse[DirectUrlRead],
)
async def member_avatar_url(
    family_id: UUID,
    user_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[DirectUrlRead]:
    """Presigned URL for a family member's avatar.

    Mirrors `/families/{fid}/members/{uid}/avatar`: the caller must be a member
    and so must the target, so a stranger gets 404 rather than a link — no
    existence leak, no cross-family reads.

    Plugin read models already carry a relative avatar URL (`author_avatar_url`)
    that `<image>` can't use. Clients swap the path suffix `/avatar` →
    `/avatar-url` on those, or call this directly when they hold the ids.
    """
    await require_membership(session, current_user.id, family_id)
    await require_membership(session, user_id, family_id)

    user = await session.get(User, user_id)
    if user is None or user.avatar_storage_key is None:
        raise AppError(ErrorCode.NOT_FOUND, "尚未设置头像", status_code=404)
    return ok(await _presign(user.avatar_storage_key))
