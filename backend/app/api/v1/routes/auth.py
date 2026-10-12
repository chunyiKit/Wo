"""Opaque bearer authentication, credential recovery and session revocation."""

from typing import Annotated

from fastapi import APIRouter, Header, Request, Response
from pydantic import BaseModel, Field

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep, parse_bearer
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.rate_limit import SlidingWindowRateLimiter, client_ip
from app.core.response import ApiResponse, ok
from app.models.user import UserRead
from app.services import auth as auth_service
from app.services import session as session_service

router = APIRouter(tags=["auth"])

# Throttles on login/register. In-memory, single-process — see
# app.core.rate_limit for the no-Redis rationale. Per-IP catches enumeration
# from one source; per-phone protects a single number from being targeted.
_login_ip_limiter = SlidingWindowRateLimiter(
    max_hits=settings.login_rate_limit_max,
    window_seconds=settings.login_rate_limit_window_seconds,
)
_login_phone_limiter = SlidingWindowRateLimiter(
    max_hits=settings.login_rate_limit_per_phone_max,
    window_seconds=settings.login_rate_limit_window_seconds,
)


def _too_many() -> AppError:
    return AppError(
        ErrorCode.RATE_LIMIT,
        "登录尝试过于频繁，请稍后再试",
        status_code=429,
    )


class LoginRequest(BaseModel):
    phone: str = Field(max_length=32)
    password: str = Field(max_length=64)


class AuthResponse(BaseModel):
    user: UserRead
    token: str  # opaque session bearer token (see app.services.session)
    is_new: bool


class ChangePasswordRequest(BaseModel):
    old_password: str = Field(default="", max_length=64)
    new_password: str = Field(max_length=64)


@router.post("/auth/login", response_model=ApiResponse[AuthResponse])
async def login(
    payload: LoginRequest, session: SessionDep, request: Request, response: Response
) -> ApiResponse[AuthResponse]:
    if not _login_ip_limiter.check(client_ip(request)):
        raise _too_many()
    # Normalize first so the phone key is stable; malformed input 422s here and
    # is only ever counted against the IP limiter above.
    phone = auth_service.normalize_phone(payload.phone)
    if not _login_phone_limiter.check(phone):
        raise _too_many()
    user, is_new = await auth_service.login_or_register(session, phone, payload.password)
    token = await session_service.issue_session(
        session, user.id, ttl_days=settings.session_ttl_days, commit=False
    )
    await session.commit()
    response.headers["Cache-Control"] = "no-store"
    return ok(
        AuthResponse(
            user=UserRead.from_user(user),
            token=token,
            is_new=is_new,
        )
    )


@router.post("/auth/logout", response_model=ApiResponse[dict])
async def logout(
    session: SessionDep,
    authorization: Annotated[str | None, Header(alias="Authorization")] = None,
) -> ApiResponse[dict]:
    """Revoke the presented session token. Idempotent — always reports success
    so a client can clear local state regardless."""
    token = parse_bearer(authorization)
    if token:
        await session_service.revoke_session(session, token)
    return ok({"logged_out": True})


@router.post("/auth/change-password", response_model=ApiResponse[dict])
async def change_password(
    payload: ChangePasswordRequest,
    request: Request,
    session: SessionDep,
    current_user: CurrentUserDep,
    authorization: Annotated[str | None, Header(alias="Authorization")] = None,
) -> ApiResponse[dict]:
    """Require current password and revoke every existing session atomically."""
    if not _login_ip_limiter.check(client_ip(request)):
        raise _too_many()
    if not _login_phone_limiter.check(str(current_user.id)):
        raise _too_many()
    current_user = await auth_service.locked_user(
        session, current_user.id, require_bearer(authorization)
    )
    await auth_service.change_password(
        session, current_user, payload.old_password, payload.new_password
    )
    return ok({"changed": True})


class RecoveryCodeRequest(BaseModel):
    password: str = Field(max_length=64)


class ResetPasswordRequest(BaseModel):
    phone: str = Field(max_length=32)
    recovery_code: str = Field(min_length=1, max_length=128)
    new_password: str = Field(max_length=64)


def require_bearer(authorization: str | None) -> str:
    token = parse_bearer(authorization)
    if not token:
        raise AppError(ErrorCode.UNAUTHORIZED, "请使用有效登录会话", status_code=401)
    return token


@router.post("/auth/recovery-code", response_model=ApiResponse[dict])
async def recovery_code(
    payload: RecoveryCodeRequest,
    session: SessionDep,
    current_user: CurrentUserDep,
    request: Request,
    response: Response,
    authorization: Annotated[str | None, Header(alias="Authorization")] = None,
) -> ApiResponse[dict]:
    if not _login_ip_limiter.check(client_ip(request)):
        raise _too_many()
    user = await auth_service.locked_user(session, current_user.id, require_bearer(authorization))
    if not _login_phone_limiter.check(str(user.id)):
        raise _too_many()
    response.headers["Cache-Control"] = "no-store"
    return ok(await auth_service.create_recovery_code(session, user, payload.password))


@router.post("/auth/reset-password", response_model=ApiResponse[dict])
async def reset_password(
    payload: ResetPasswordRequest,
    session: SessionDep,
    request: Request,
) -> ApiResponse[dict]:
    if not _login_ip_limiter.check(client_ip(request)):
        raise _too_many()
    phone = auth_service.normalize_phone(payload.phone)
    if not _login_phone_limiter.check(phone):
        raise _too_many()
    await auth_service.reset_password(session, phone, payload.recovery_code, payload.new_password)
    return ok({"changed": True, "logged_out": True})


@router.post("/auth/logout-all", response_model=ApiResponse[dict])
async def logout_all(
    session: SessionDep,
    current_user: CurrentUserDep,
    authorization: Annotated[str | None, Header(alias="Authorization")] = None,
) -> ApiResponse[dict]:
    user = await auth_service.locked_user(session, current_user.id, require_bearer(authorization))
    await auth_service.revoke_all(session, user.id)
    await session.commit()
    return ok({"logged_out": True})
