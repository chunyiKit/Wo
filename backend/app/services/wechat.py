"""服务端微信身份验证；上游替身只能由测试依赖覆盖注入。"""

import logging
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import httpx
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.password import hash_password
from app.models.user import User
from app.models.wechat_identity import WechatIdentity
from app.services import auth
from app.services.session import _hash_token


class _WechatRequestLogFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        # httpx INFO logs complete request URLs, including code/AppSecret query
        # parameters. Redact this endpoint even when app logging is enabled.
        if "jscode2session" in record.getMessage():
            record.msg = "WeChat code exchange request (credentials redacted)"
            record.args = ()
        return True


logging.getLogger("httpx").addFilter(_WechatRequestLogFilter())
logging.getLogger("httpcore").addFilter(_WechatRequestLogFilter())


@dataclass(frozen=True)
class VerifiedWechatIdentity:
    app_id: str
    openid: str


async def exchange_code(code: str) -> VerifiedWechatIdentity:
    """只允许固定微信 HTTPS 上游；不返回/记录 session_key、code 或上游响应。"""
    if not settings.wechat_app_id or not settings.wechat_app_secret:
        raise AppError(ErrorCode.INTERNAL, "微信登录尚未配置，请联系管理员", status_code=503)
    try:
        async with httpx.AsyncClient(timeout=settings.wechat_timeout_seconds) as client:
            response = await client.get(
                "https://api.weixin.qq.com/sns/jscode2session",
                params={
                    "appid": settings.wechat_app_id,
                    "secret": settings.wechat_app_secret.get_secret_value(),
                    "js_code": code,
                    "grant_type": "authorization_code",
                },
            )
            response.raise_for_status()
            payload = response.json()
    except (httpx.HTTPError, ValueError):
        # Never interpolate the exception: its URL may contain the AppSecret.
        raise AppError(ErrorCode.INTERNAL, "微信登录服务暂不可用，请重试", 502) from None
    if not isinstance(payload, dict) or payload.get("errcode"):
        raise AppError(ErrorCode.UNAUTHORIZED, "微信登录凭据无效，请重新登录", 401)
    openid = payload.get("openid")
    session_key = payload.get("session_key")
    if not isinstance(openid, str) or not 1 <= len(openid) <= 128 or not session_key:
        raise AppError(ErrorCode.UNAUTHORIZED, "微信登录凭据无效，请重新登录", 401)
    return VerifiedWechatIdentity(settings.wechat_app_id, openid)


async def identity_row(session: AsyncSession, identity: VerifiedWechatIdentity):
    return (
        await session.execute(
            select(WechatIdentity).where(
                WechatIdentity.app_id == identity.app_id,
                WechatIdentity.openid == identity.openid,
            )
        )
    ).scalar_one_or_none()


async def login_user(session: AsyncSession, identity: VerifiedWechatIdentity) -> User | None:
    mapping = await identity_row(session, identity)
    if mapping is None:
        return None
    # Same row lock as recovery/logout-all/password login: issuance cannot slip
    # into a credential revocation transaction.
    user = (
        await session.execute(
            select(User)
            .where(User.id == mapping.user_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    ).scalar_one_or_none()
    if user is None or not user.password_hash:
        raise AppError(ErrorCode.UNAUTHORIZED, "账号需完成可信恢复后重新登录", 401)
    return user


def _conflict() -> AppError:
    return AppError(ErrorCode.FORBIDDEN, "微信身份已绑定；请重新登录或联系管理员核验", 409)


async def register_user(
    session: AsyncSession, identity: VerifiedWechatIdentity, password: str, display_name: str
) -> tuple[User, str, datetime]:
    auth.validate_password(password)
    if await identity_row(session, identity) is not None:
        raise _conflict()
    recovery_code = secrets.token_urlsafe(32)
    expires = datetime.now(UTC) + timedelta(days=365)
    user = User(
        username=f"wx{secrets.token_hex(12)}",
        display_name=display_name,
        password_hash=hash_password(password),
        recovery_code_hash=_hash_token(recovery_code),
        recovery_expires_at=expires,
    )
    session.add(user)
    try:
        await session.flush()
        session.add(
            WechatIdentity(
                app_id=identity.app_id,
                openid=identity.openid,
                user_id=user.id,
            )
        )
        await session.flush()
    except IntegrityError:
        # Unique constraints cover parallel first registrations/bindings. The
        # whole transaction rolls back, including a just-created orphan user.
        await session.rollback()
        raise _conflict() from None
    return user, recovery_code, expires


async def bind_user(
    session: AsyncSession, identity: VerifiedWechatIdentity, phone: str, password: str
) -> User:
    user = (
        await session.execute(
            select(User)
            .where(User.phone == auth.normalize_phone(phone))
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    ).scalar_one_or_none()
    if user is None:
        # Match password verification cost without ever registering a phone.
        auth.require_password(User(username="invalid", display_name="invalid"), password)
    auth.require_password(user, password)
    existing = await identity_row(session, identity)
    if existing is not None:
        if existing.user_id != user.id:
            raise _conflict()
        return user
    session.add(WechatIdentity(app_id=identity.app_id, openid=identity.openid, user_id=user.id))
    try:
        await session.flush()
    except IntegrityError:
        await session.rollback()
        raise _conflict() from None
    return user


async def reset_password(
    session: AsyncSession, identity: VerifiedWechatIdentity, recovery_code: str, new_password: str
) -> None:
    auth.validate_password(new_password)
    user = await login_user(session, identity)
    expires = user.recovery_expires_at if user else None
    if expires and expires.tzinfo is None:
        expires = expires.replace(tzinfo=UTC)
    matches = secrets.compare_digest(
        _hash_token(recovery_code),
        (user.recovery_code_hash if user else None) or "0" * 64,
    )
    if not matches or not expires or expires <= datetime.now(UTC):
        raise AppError(ErrorCode.UNAUTHORIZED, "账号或恢复码无效、已过期或已使用", 401)
    user.password_hash = hash_password(new_password)
    user.recovery_code_hash = None
    user.recovery_expires_at = None
    session.add(user)
    await auth.revoke_all(session, user.id)
    await session.commit()
