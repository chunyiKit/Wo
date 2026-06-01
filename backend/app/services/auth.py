"""Phone-number auth — login / register / password.

`login_or_register` normalizes the phone and:
- new number → registers a user with the given password,
- known number that already has a password → verifies it,
- known number without a password (legacy row) → sets the given password on
  this first login (so "existing users must set a password" is satisfied
  transparently — the login screen's password field becomes their password).

Passwords are stored only as scrypt hashes (see app.core.password). The
returned user's id doubles as the "token" the dev auth shim (`app.core.auth`)
reads from the `X-User-Id` header.
"""

import re

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.errors import AppError, ErrorCode
from app.core.password import hash_password, verify_password
from app.models.user import User

# Mainland China mobile: 11 digits, leading 1, second digit 3-9.
_PHONE_RE = re.compile(r"^1[3-9]\d{9}$")

MIN_PASSWORD_LEN = 6
MAX_PASSWORD_LEN = 64


def validate_password(password: str) -> str:
    """Enforce basic length bounds. Raises VALIDATION_ERROR on a bad password."""
    if not password or len(password) < MIN_PASSWORD_LEN:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            f"密码至少 {MIN_PASSWORD_LEN} 位",
            status_code=422,
        )
    if len(password) > MAX_PASSWORD_LEN:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            f"密码最多 {MAX_PASSWORD_LEN} 位",
            status_code=422,
        )
    return password


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


async def login_or_register(
    session: AsyncSession, raw_phone: str, password: str
) -> tuple[User, bool]:
    """Authenticate or register a phone with a password. Returns (user, is_new).

    Raises UNAUTHORIZED when a known account's password doesn't match, and
    VALIDATION_ERROR for a too-short/long password.
    """
    phone = normalize_phone(raw_phone)
    validate_password(password)

    existing = (
        await session.execute(select(User).where(User.phone == phone))
    ).scalar_one_or_none()
    if existing is not None:
        if existing.password_hash:
            if not verify_password(password, existing.password_hash):
                raise AppError(
                    ErrorCode.UNAUTHORIZED, "手机号或密码错误", status_code=401
                )
        else:
            # Legacy account with no password yet → set it on this first login.
            existing.password_hash = hash_password(password)
            session.add(existing)
            await session.commit()
            await session.refresh(existing)
        return existing, False

    user = User(
        phone=phone,
        username=f"u{phone}",
        display_name=f"用户{phone[-4:]}",
        avatar_emoji="👤",
        password_hash=hash_password(password),
    )
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return user, True


async def change_password(
    session: AsyncSession, user: User, old_password: str, new_password: str
) -> None:
    """Change the current user's password. Verifies `old_password` when one is
    already set; raises UNAUTHORIZED if it doesn't match."""
    validate_password(new_password)
    if user.password_hash and not verify_password(old_password, user.password_hash):
        raise AppError(ErrorCode.UNAUTHORIZED, "原密码不正确", status_code=401)
    user.password_hash = hash_password(new_password)
    session.add(user)
    await session.commit()
