"""Request authentication.

Primary path: an opaque bearer token (`Authorization: Bearer <token>`) minted
at login and resolved against the `auth_sessions` table (see
app.services.session). This can't be forged — the token is high-entropy and
server-stored.

Legacy dev shim: when `settings.auth_dev_shim_enabled` is True, a request may
instead carry `X-User-Id: <uuid>` (and defaults to the seed user when absent).
This is how dev and the test-suite act as specific users. Production sets the
flag False so only bearer tokens are accepted.
"""

from typing import Annotated
from uuid import UUID

from fastapi import Depends, Header

from app.api.deps import SessionDep
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.ids import SEED_USER_ID
from app.models.user import User
from app.services.session import resolve_user_id


def _unauthorized(message: str = "未登录或登录已过期，请重新登录") -> AppError:
    return AppError(ErrorCode.UNAUTHORIZED, message, status_code=401)


def parse_bearer(authorization: str | None) -> str | None:
    """Extract the token from an `Authorization: Bearer <token>` header."""
    if not authorization:
        return None
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        return None
    return token.strip()


async def get_current_user(
    session: SessionDep,
    authorization: Annotated[str | None, Header(alias="Authorization")] = None,
    x_user_id: Annotated[str | None, Header(alias="X-User-Id")] = None,
) -> User:
    # 1) Real bearer token (the production path).
    token = parse_bearer(authorization)
    if token is not None:
        user_id = await resolve_user_id(session, token)
        if user_id is None:
            raise _unauthorized()
        user = await session.get(User, user_id)
        if user is None:
            raise _unauthorized()
        return user
    # A malformed Authorization header is an explicit auth failure.
    if authorization:
        raise _unauthorized("无效的 Authorization 头")

    # 2) Dev/test shim — only when enabled.
    if not settings.auth_dev_shim_enabled:
        raise _unauthorized()

    if x_user_id:
        try:
            target_id = UUID(x_user_id)
        except ValueError as exc:
            raise AppError(
                ErrorCode.UNAUTHORIZED,
                "Invalid X-User-Id header (not a UUID)",
                status_code=401,
            ) from exc
    else:
        target_id = SEED_USER_ID

    user = await session.get(User, target_id)
    if user is None:
        raise AppError(
            ErrorCode.UNAUTHORIZED,
            "Unknown user — did the lifespan seed run?",
            status_code=401,
            details={"user_id": str(target_id)},
        )
    return user


CurrentUserDep = Annotated[User, Depends(get_current_user)]
