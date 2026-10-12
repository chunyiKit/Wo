"""Password authentication and one-time, pre-enrolled account recovery."""

import re
import secrets
from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy import delete
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.errors import AppError, ErrorCode
from app.core.password import hash_password, verify_password
from app.models.auth_session import AuthSession
from app.models.user import User
from app.services.session import _hash_token, resolve_user_id

# Mainland China mobile: 11 digits, leading 1, second digit 3-9.
_PHONE_RE = re.compile(r"^1[3-9]\d{9}$")

MIN_PASSWORD_LEN = 6
MAX_PASSWORD_LEN = 64
_DUMMY_PASSWORD_HASH = hash_password("invalid-account-placeholder")
_LOGIN_ERROR = "手机号或密码错误；忘记密码请使用恢复码，无恢复凭据的旧账号需线下核验迁移"


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
        await session.execute(select(User).where(User.phone == phone).with_for_update())
    ).scalar_one_or_none()
    if existing is not None:
        valid = verify_password(password, existing.password_hash or _DUMMY_PASSWORD_HASH)
        if not existing.password_hash or not valid:
            raise AppError(ErrorCode.UNAUTHORIZED, _LOGIN_ERROR, status_code=401)
        return existing, False

    user = User(
        phone=phone,
        username=f"u{phone}",
        display_name=f"用户{phone[-4:]}",
        avatar_emoji="👤",
        password_hash=hash_password(password),
    )
    session.add(user)
    try:
        await session.flush()
    except IntegrityError as exc:
        await session.rollback()
        raise AppError(ErrorCode.UNAUTHORIZED, _LOGIN_ERROR, status_code=401) from exc
    return user, True


async def locked_user(session: AsyncSession, user_id: UUID, token: str) -> User:
    """Serialize auth mutations/issuance and recheck bearer after waiting for the lock."""
    user = (
        await session.execute(
            select(User)
            .where(User.id == user_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    ).scalar_one()
    if await resolve_user_id(session, token) != user_id:
        raise AppError(
            ErrorCode.UNAUTHORIZED,
            "登录已失效，请重新登录",
            status_code=401,
            details={"session_invalid": True},
        )
    return user


def require_password(user: User, password: str) -> None:
    valid = verify_password(password, user.password_hash or _DUMMY_PASSWORD_HASH)
    if not user.password_hash or not valid:
        raise AppError(
            ErrorCode.UNAUTHORIZED, "原密码不正确；无密码旧账号需线下核验迁移", status_code=401
        )


async def revoke_all(session: AsyncSession, user_id: UUID) -> None:
    # Caller holds the user row lock; commit together with credential changes.
    await session.execute(delete(AuthSession).where(AuthSession.user_id == user_id))


async def change_password(
    session: AsyncSession, user: User, old_password: str, new_password: str
) -> None:
    validate_password(new_password)
    require_password(user, old_password)
    user.password_hash = hash_password(new_password)
    # Rotate credentials: an old recovery code must not undo a password change.
    user.recovery_code_hash = None
    user.recovery_expires_at = None
    session.add(user)
    await revoke_all(session, user.id)
    await session.commit()


async def create_recovery_code(session: AsyncSession, user: User, password: str) -> dict:
    require_password(user, password)
    code = secrets.token_urlsafe(32)
    expires = datetime.now(UTC) + timedelta(days=365)
    user.recovery_code_hash = _hash_token(code)
    user.recovery_expires_at = expires
    session.add(user)
    await session.commit()
    return {"recovery_code": code, "expires_at": expires.isoformat()}


async def reset_password(
    session: AsyncSession, phone: str, recovery_code: str, new_password: str
) -> None:
    phone = normalize_phone(phone)
    validate_password(new_password)
    user = (
        await session.execute(
            select(User)
            .where(User.phone == phone)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    ).scalar_one_or_none()
    expires = user.recovery_expires_at if user else None
    if expires and expires.tzinfo is None:
        expires = expires.replace(tzinfo=UTC)
    matches = secrets.compare_digest(
        _hash_token(recovery_code),
        (user.recovery_code_hash if user else None) or "0" * 64,
    )
    if not matches or not expires or expires <= datetime.now(UTC):
        raise AppError(
            ErrorCode.UNAUTHORIZED,
            "账号或恢复码无效、已过期或已使用；无恢复凭据需线下核验迁移",
            status_code=401,
        )
    user.password_hash = hash_password(new_password)
    user.recovery_code_hash = None
    user.recovery_expires_at = None
    session.add(user)
    await revoke_all(session, user.id)
    await session.commit()
