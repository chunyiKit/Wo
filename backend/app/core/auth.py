"""Authentication shim for P1/P2 — defaults to seed user, override via header.

In dev mode every request is treated as if the seed user (老陈) made it. To
test multi-user flows (invite → accept across two accounts), the client may
send `X-User-Id: <uuid>` to act as a different seeded user. P5 will replace
this with real JWT parsing.
"""

from typing import Annotated
from uuid import UUID

from fastapi import Depends, Header

from app.api.deps import SessionDep
from app.core.errors import AppError, ErrorCode
from app.core.ids import SEED_USER_ID
from app.models.user import User


async def get_current_user(
    session: SessionDep,
    x_user_id: Annotated[str | None, Header(alias="X-User-Id")] = None,
) -> User:
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
