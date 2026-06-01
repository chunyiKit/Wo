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

_TOKEN_BYTES = 32


def _hash_token(raw_token: str) -> str:
    return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()


async def issue_session(
    session: AsyncSession, user_id: UUID, *, ttl_days: int
) -> str:
    """Create a session for `user_id` and return the raw token (shown once)."""
    raw_token = secrets.token_urlsafe(_TOKEN_BYTES)
    row = AuthSession(
        user_id=user_id,
        token_hash=_hash_token(raw_token),
        expires_at=datetime.now(UTC) + timedelta(days=ttl_days),
    )
    session.add(row)
    await session.commit()
    return raw_token


async def resolve_user_id(session: AsyncSession, raw_token: str) -> UUID | None:
    """Return the user id for a valid, unexpired token, else None."""
    if not raw_token:
        return None
    row = (
        await session.execute(
            select(AuthSession).where(AuthSession.token_hash == _hash_token(raw_token))
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
    await session.execute(
        delete(AuthSession).where(AuthSession.token_hash == _hash_token(raw_token))
    )
    await session.commit()


__all__ = ["issue_session", "resolve_user_id", "revoke_session"]
