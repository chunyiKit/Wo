"""Auth endpoints — phone-number login / register.

`POST /auth/login` takes a phone number and returns the user plus a `token`.
There is no SMS code step yet (P5): an unknown phone is registered on the
spot, a known phone logs in. The `token` is the user id — the dev auth shim
(`app.core.auth`) reads it from the `X-User-Id` header on later requests.
"""

from fastapi import APIRouter, Request
from pydantic import BaseModel

from app.api.deps import SessionDep
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.rate_limit import SlidingWindowRateLimiter, client_ip
from app.core.response import ApiResponse, ok
from app.models.user import UserRead
from app.services import auth as auth_service

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
    phone: str


class AuthResponse(BaseModel):
    user: UserRead
    token: str  # currently the user id; swap for a JWT when real auth lands
    is_new: bool


@router.post("/auth/login", response_model=ApiResponse[AuthResponse])
async def login(
    payload: LoginRequest, session: SessionDep, request: Request
) -> ApiResponse[AuthResponse]:
    if not _login_ip_limiter.check(client_ip(request)):
        raise _too_many()
    # Normalize first so the phone key is stable; malformed input 422s here and
    # is only ever counted against the IP limiter above.
    phone = auth_service.normalize_phone(payload.phone)
    if not _login_phone_limiter.check(phone):
        raise _too_many()
    user, is_new = await auth_service.login_or_register(session, phone)
    return ok(
        AuthResponse(
            user=UserRead.model_validate(user, from_attributes=True),
            token=str(user.id),
            is_new=is_new,
        )
    )
