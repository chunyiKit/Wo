"""Invitation = an ephemeral code that turns into a Membership when accepted.

The code is stored as an 8-char uppercase alnum slug (the PK). For display we
format it as `WO-XXXX-XXXX`; for URLs we use the raw slug. Translation lives
in `app/services/invitation.py`.
"""

from datetime import datetime
from typing import Literal
from uuid import UUID

from sqlalchemy import Column, DateTime
from sqlmodel import Field, SQLModel

InvitationChannel = Literal["qr", "link", "code"]


class Invitation(SQLModel, table=True):
    __tablename__ = "invitations"

    # Slug form, e.g. "W4M9P2KX". Display form is "WO-W4M9-P2KX".
    code: str = Field(primary_key=True, max_length=16)

    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    inviter_id: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )
    role: str = Field(default="member", max_length=16)
    channel: str = Field(default="link", max_length=16)

    expires_at: datetime = Field(
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    used_at: datetime | None = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True),
    )
    used_by_user_id: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )
    created_at: datetime = Field(
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
