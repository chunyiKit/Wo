"""User domain model.

Matches the User shape defined in docs/backend-contract.md §5.1 / appendix A.

`phone` backs the phone-number login flow (`/auth/login`). SMS verification is
not wired yet — login currently just looks the phone up (and registers it if
new). OAuth/Passkey columns will follow. `phone` is nullable so legacy/seed
rows created before P5 stay valid.

`current_family_id` is normally encoded in the JWT (see contract §4.3); in dev
mode we persist it on the user row so the shim `get_current_user` can resolve
it without a token.
"""

from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, StringConstraints
from sqlalchemy import Column, DateTime
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7


class UserBase(SQLModel):
    username: str = Field(unique=True, index=True, max_length=32)
    display_name: str = Field(max_length=24)
    avatar_emoji: str = Field(default="👤", max_length=16)
    level: int = Field(default=1, ge=1)


class User(UserBase, table=True):
    __tablename__ = "users"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    # Optional uploaded avatar photo. When absent the client falls back to
    # `avatar_emoji`. `avatar_version` bumps on every (re)upload so clients can
    # cache the raw-bytes URL by version and refresh only when it changes.
    avatar_storage_key: str | None = Field(default=None, max_length=255)
    avatar_content_type: str | None = Field(default=None, max_length=64)
    avatar_version: int = Field(default=0, ge=0)
    # Login identifier. Nullable + unique: pre-P5 rows may lack a phone, but no
    # two users can share one. Not exposed in UserRead (kept off public reads).
    phone: str | None = Field(default=None, max_length=20, unique=True, index=True)
    current_family_id: UUID | None = Field(
        default=None,
        foreign_key="families.id",
        ondelete="SET NULL",
        nullable=True,
    )
    # 通知偏好（系统推送层面）。形如：
    #   {"push_enabled": bool, "sources": {"<source_key>": bool, ...}}
    # 缺省键视为开启（opt-out），所以老用户在显式关闭前照常收到全部推送。
    # 仅影响是否推送到手机系统通知栏；站内消息中心始终记录。
    notification_prefs: dict = Field(
        default_factory=dict,
        sa_column=Column(JSONB, nullable=False, server_default="{}"),
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class UserUpdate(BaseModel):
    """PATCH /me request body — 每个字段可选，仅更新提供的字段。"""

    display_name: Annotated[str, StringConstraints(min_length=1, max_length=24)] | None = None


def build_avatar_url(version: int) -> str:
    """Relative raw-bytes URL for the current user's avatar, with a `?v=`
    cache-buster keyed on the version so cached bytes never go stale."""
    return f"/api/v1/me/avatar?v={version}"


class UserRead(UserBase):
    """Public user shape — what the API returns."""

    id: UUID
    created_at: datetime
    # Avatar photo: version (0 = none) + a relative raw-bytes URL with a `?v=`
    # cache-buster. `avatar_url` is None when no photo uploaded, in which case
    # the client renders `avatar_emoji` instead.
    avatar_version: int = 0
    avatar_url: str | None = None

    @classmethod
    def from_user(cls, user: "User") -> "UserRead":
        read = cls.model_validate(user, from_attributes=True)
        if user.avatar_storage_key is not None:
            read = read.model_copy(update={"avatar_url": build_avatar_url(user.avatar_version)})
        return read
