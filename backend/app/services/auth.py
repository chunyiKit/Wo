"""Phone-number auth — login / register.

P5 will add SMS code send + verify; for now there is no code step. `login`
normalizes the phone, looks the user up, and registers a fresh user when the
number is new. The returned user's id doubles as the "token" the dev auth shim
(`app.core.auth`) reads from the `X-User-Id` header.
"""

import re

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.errors import AppError, ErrorCode
from app.models.user import User

# Mainland China mobile: 11 digits, leading 1, second digit 3-9.
_PHONE_RE = re.compile(r"^1[3-9]\d{9}$")


def normalize_phone(raw: str) -> str:
    """Strip spaces/dashes/+86 and validate. Raises on malformed input."""
    cleaned = re.sub(r"[\s\-]", "", raw or "")
    if cleaned.startswith("+86"):
        cleaned = cleaned[3:]
    elif cleaned.startswith("86") and len(cleaned) == 13:
        cleaned = cleaned[2:]
    if not _PHONE_RE.match(cleaned):
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            "手机号格式不正确",
            status_code=422,
            details={"phone": raw},
        )
    return cleaned


async def login_or_register(session: AsyncSession, raw_phone: str) -> tuple[User, bool]:
    """Find the user for this phone, or create one. Returns (user, is_new)."""
    phone = normalize_phone(raw_phone)

    existing = (await session.execute(select(User).where(User.phone == phone))).scalar_one_or_none()
    if existing is not None:
        return existing, False

    user = User(
        phone=phone,
        username=f"u{phone}",
        display_name=f"用户{phone[-4:]}",
        avatar_emoji="👤",
    )
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return user, True
