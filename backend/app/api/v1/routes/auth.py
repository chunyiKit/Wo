"""Auth endpoints — phone-number login / register.

`POST /auth/login` takes a phone number and returns the user plus a `token`.
There is no SMS code step yet (P5): an unknown phone is registered on the
spot, a known phone logs in. The `token` is the user id — the dev auth shim
(`app.core.auth`) reads it from the `X-User-Id` header on later requests.
"""

from fastapi import APIRouter
from pydantic import BaseModel

from app.api.deps import SessionDep
from app.core.response import ApiResponse, ok
from app.models.user import UserRead
from app.services import auth as auth_service

router = APIRouter(tags=["auth"])


class LoginRequest(BaseModel):
    phone: str


class AuthResponse(BaseModel):
    user: UserRead
    token: str  # currently the user id; swap for a JWT when real auth lands
    is_new: bool


@router.post("/auth/login", response_model=ApiResponse[AuthResponse])
async def login(payload: LoginRequest, session: SessionDep) -> ApiResponse[AuthResponse]:
    user, is_new = await auth_service.login_or_register(session, payload.phone)
    return ok(
        AuthResponse(
            user=UserRead.model_validate(user, from_attributes=True),
            token=str(user.id),
            is_new=is_new,
        )
    )
