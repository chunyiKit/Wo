"""Device endpoints — register/unregister a JPush registration id for pushes.

The app calls `POST /devices/register` once it has a JPush registration id (and
again on refresh), and `DELETE /devices/{registration_id}` on logout.
"""

from typing import Annotated, Literal

from fastapi import APIRouter
from pydantic import BaseModel, StringConstraints

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.response import ApiResponse, ok
from app.models.device_token import DeviceTokenRead
from app.services import device_token as device_service

router = APIRouter(prefix="/devices", tags=["devices"])


class RegisterDeviceRequest(BaseModel):
    registration_id: Annotated[str, StringConstraints(min_length=1, max_length=64)]
    platform: Literal["ios", "android"]


@router.post("/register", response_model=ApiResponse[DeviceTokenRead])
async def register_device(
    body: RegisterDeviceRequest,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[DeviceTokenRead]:
    token = await device_service.register_device(
        session,
        user_id=current_user.id,
        registration_id=body.registration_id,
        platform=body.platform,
    )
    return ok(DeviceTokenRead.model_validate(token, from_attributes=True))


@router.delete("/{registration_id}", response_model=ApiResponse[None])
async def unregister_device(
    registration_id: str,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[None]:
    await device_service.unregister_device(
        session,
        registration_id=registration_id,
        user_id=current_user.id,
    )
    return ok(None)
