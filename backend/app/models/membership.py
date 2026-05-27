"""Membership = the User × Family association with role + per-family identity.

The user's `display_name` and `avatar_emoji` on a Membership may override the
ones on User, so 老陈 can appear as "爸爸" in one family and "老陈" in another
(see contract §5.3).
"""

from datetime import UTC, datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel
from sqlalchemy import Column, DateTime
from sqlmodel import Field, SQLModel

Role = Literal["owner", "admin", "member", "child", "pet"]
MembershipStatus = Literal["active", "pending"]

# Allowed values for role-gating helpers (keep in sync with the Literal above).
ALL_ROLES: tuple[str, ...] = ("owner", "admin", "member", "child", "pet")
ADMIN_OR_OWNER: tuple[str, ...] = ("owner", "admin")
INVITABLE_ROLES: tuple[str, ...] = ("admin", "member", "child", "pet")
# Note: "owner" cannot be invited — ownership transfers go through a separate
# transfer endpoint (P2.5+).


class Membership(SQLModel, table=True):
    __tablename__ = "memberships"

    user_id: UUID = Field(
        foreign_key="users.id",
        primary_key=True,
        ondelete="CASCADE",
    )
    family_id: UUID = Field(
        foreign_key="families.id",
        primary_key=True,
        ondelete="CASCADE",
    )
    role: str = Field(default="member", max_length=16)
    display_name: str = Field(max_length=24)
    avatar_emoji: str = Field(default="👤", max_length=16)
    status: str = Field(default="active", max_length=16)
    joined_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class MembershipRead(BaseModel):
    user_id: UUID
    family_id: UUID
    role: Role
    display_name: str
    avatar_emoji: str
    # Member-avatar URL when this user uploaded a real photo; None → emoji.
    # Injected server-side (see members route) since it lives on User, not here.
    avatar_url: str | None = None
    joined_at: datetime
    status: MembershipStatus
