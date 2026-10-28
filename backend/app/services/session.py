"""Session-token service — issue / resolve / revoke opaque bearer tokens.

The raw token is `secrets.token_urlsafe(...)` (high entropy); only its SHA-256
hash is stored (see app.models.auth_session). Resolution hashes the presented
token and looks the row up, rejecting expired sessions. Revocation deletes the
row, so logout / lost-device invalidation is immediate.
"""

from __future__ import annotations

import hashlib
import secrets
from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.auth_session import AuthSession
from app.models.device_token import DeviceToken
from app.models.user import User

_TOKEN_BYTES = 32

# Which client a session was minted for. Stored on `auth_sessions.client`.
CLIENT_APP = "app"  # Android app
CLIENT_MP = "mp"  # 微信小程序


def _hash_token(raw_token: str) -> str:
    return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()


async def issue_session(
    session: AsyncSession,
    user_id: UUID,
    *,
    ttl_days: int,
    commit: bool = True,
    client: str = CLIENT_APP,
) -> str:
    """Create a session for `user_id` and return the raw token (shown once).

    `client` records where the token was minted — `CLIENT_APP` (Android) or
    `CLIENT_MP` (微信小程序). Descriptive only; see the AuthSession model.
    """
    raw_token = secrets.token_urlsafe(_TOKEN_BYTES)
    row = AuthSession(
        user_id=user_id,
        token_hash=_hash_token(raw_token),
        expires_at=datetime.now(UTC) + timedelta(days=ttl_days),
        client=client,
    )
    session.add(row)
    if commit:
        await session.commit()
    else:
        await session.flush()
    return raw_token


async def resolve_user_id(session: AsyncSession, raw_token: str) -> UUID | None:
    """Return the user id for a valid, unexpired token, else None."""
    if not raw_token:
        return None
    row = (
        await session.execute(
            select(AuthSession)
            .join(User, User.id == AuthSession.user_id)
            .where(
                AuthSession.token_hash == _hash_token(raw_token),
                User.deleted_at.is_(None),
                User.password_hash.is_not(None),
                User.password_hash != "",
            )
        )
    ).scalar_one_or_none()
    if row is None:
        return None
    expires_at = row.expires_at
    # Stored as tz-aware UTC; guard against a naive value just in case.
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=UTC)
    if expires_at <= datetime.now(UTC):
        return None
    return row.user_id


async def revoke_session(session: AsyncSession, raw_token: str) -> None:
    """Delete the session for this token (idempotent — no error if absent)."""
    if not raw_token:
        return
    user_id = (
        await session.execute(
            select(AuthSession.user_id).where(AuthSession.token_hash == _hash_token(raw_token))
        )
    ).scalar_one_or_none()
    if user_id is not None:
        # Same lock as issuance/recovery/all-session revocation. Waiting auth
        # mutations will recheck this token only after the deletion commits.
        await session.execute(select(User.id).where(User.id == user_id).with_for_update())
        # Unattributable old records are fail-closed; other bound sessions survive.
        await session.execute(
            delete(DeviceToken).where(
                DeviceToken.user_id == user_id,
                DeviceToken.session_id.is_(None),
            )
        )
        await session.execute(
            delete(AuthSession).where(AuthSession.token_hash == _hash_token(raw_token))
        )
    await session.commit()


__all__ = [
    "CLIENT_APP",
    "CLIENT_MP",
    "issue_session",
    "resolve_user_id",
    "revoke_session",
]
