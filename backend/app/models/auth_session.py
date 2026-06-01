"""Auth session table — opaque, revocable bearer tokens.

Login mints a high-entropy random token and stores only its SHA-256 hash here
(the raw token is shown to the client once and never persisted). Each request
carrying `Authorization: Bearer <token>` is authenticated by hashing the token
and looking the row up; logout deletes the row, so a token dies the moment the
user signs out (unlike a stateless JWT). The token is random — not a password —
so a plain SHA-256 (no per-row salt/KDF) is the right, fast choice for lookup.
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import Column, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7


class AuthSession(SQLModel, table=True):
    __tablename__ = "auth_sessions"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    user_id: UUID = Field(
        foreign_key="users.id",
        ondelete="CASCADE",
        index=True,
    )
    # SHA-256 hex of the raw token (64 chars). Unique + indexed for O(1) lookup.
    token_hash: str = Field(max_length=64, unique=True, index=True)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    expires_at: datetime = Field(
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
