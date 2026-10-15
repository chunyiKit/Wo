"""独立微信登录入口，现有手机端的身份/session 行为保持兼容。"""

from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, Field

from app.api.deps import SessionDep
from app.api.v1.routes.auth import AuthResponse, _too_many
from app.core.config import settings
from app.core.rate_limit import SlidingWindowRateLimiter, client_ip
from app.core.response import ApiResponse, ok
from app.models.user import UserRead
from app.services import auth, wechat
from app.services.session import issue_session

router = APIRouter(prefix="/auth/wechat", tags=["auth"])
_ip_limiter = SlidingWindowRateLimiter(
    max_hits=settings.login_rate_limit_max,
    window_seconds=settings.login_rate_limit_window_seconds,
)
_identity_limiter = SlidingWindowRateLimiter(
    max_hits=settings.login_rate_limit_per_phone_max,
    window_seconds=settings.login_rate_limit_window_seconds,
)


class CodeRequest(BaseModel):
    code: str = Field(min_length=1, max_length=256)


class RegisterRequest(CodeRequest):
    password: str = Field(min_length=6, max_length=64)
    display_name: str = Field(default="微信用户", min_length=1, max_length=24)


class BindRequest(CodeRequest):
    phone: str = Field(max_length=32)
    password: str = Field(max_length=64)


class ResetRequest(CodeRequest):
    recovery_code: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=6, max_length=64)


async def verified_identity(
    request: Request, payload: CodeRequest
) -> wechat.VerifiedWechatIdentity:
    if not _ip_limiter.check(client_ip(request)):
        raise _too_many()
    identity = await wechat.exchange_code(payload.code)
    if not _identity_limiter.check(f"{identity.app_id}:{identity.openid}"):
        raise _too_many()
    return identity


IdentityDep = Annotated[wechat.VerifiedWechatIdentity, Depends(verified_identity)]


async def auth_result(session, user, response: Response, *, is_new: bool = False, **extra):
    token = await issue_session(session, user.id, ttl_days=settings.session_ttl_days, commit=False)
    await session.commit()
    response.headers["Cache-Control"] = "no-store"
    return ok(
        {
            **AuthResponse(user=UserRead.from_user(user), token=token, is_new=is_new).model_dump(
                mode="json"
            ),
            **extra,
        }
    )


@router.post("/login", response_model=ApiResponse[dict])
async def login(identity: IdentityDep, session: SessionDep, response: Response):
    response.headers["Cache-Control"] = "no-store"
    user = await wechat.login_user(session, identity)
    if user is None:
        return ok({"registration_required": True})
    return await auth_result(session, user, response)


@router.post("/register", response_model=ApiResponse[dict])
async def register(
    payload: RegisterRequest, identity: IdentityDep, session: SessionDep, response: Response
):
    user, code, expires = await wechat.register_user(
        session,
        identity,
        payload.password,
        payload.display_name,
    )
    return await auth_result(
        session,
        user,
        response,
        is_new=True,
        recovery_code=code,
        recovery_expires_at=expires.isoformat(),
    )


@router.post("/bind", response_model=ApiResponse[dict])
async def bind(
    payload: BindRequest, identity: IdentityDep, session: SessionDep, response: Response
):
    phone = auth.normalize_phone(payload.phone)
    # Share the phone-login limiter, so changing wx identity cannot multiply
    # guesses against an existing account.
    from app.api.v1.routes.auth import _login_phone_limiter

    if not _login_phone_limiter.check(phone):
        raise _too_many()
    user = await wechat.bind_user(session, identity, phone, payload.password)
    return await auth_result(session, user, response)


@router.post("/reset-password", response_model=ApiResponse[dict])
async def reset(
    payload: ResetRequest, identity: IdentityDep, session: SessionDep, response: Response
):
    await wechat.reset_password(session, identity, payload.recovery_code, payload.new_password)
    response.headers["Cache-Control"] = "no-store"
    return ok({"changed": True, "logged_out": True})
