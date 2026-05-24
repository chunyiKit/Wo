"""Notification domain model.

Notifications belong to a recipient (`user_id`). Family-scoped events also
carry `family_id` so the client can deep-link back; deletion of a family sets
that nullable FK to NULL so the notification stays as a historical artifact.
"""

from datetime import UTC, datetime
from uuid import UUID

from pydantic import BaseModel
from sqlalchemy import Column, DateTime, Index
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7


class Notification(SQLModel, table=True):
    __tablename__ = "notifications"
    __table_args__ = (
        # The common query is "my unread notifications, newest first". The
        # composite (user_id, read_at, created_at desc) lets PG answer that
        # with a single index scan.
        Index(
            "ix_notifications_user_unread_created",
            "user_id",
            "read_at",
            "created_at",
        ),
    )

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)

    user_id: UUID = Field(
        foreign_key="users.id",
        ondelete="CASCADE",
        index=True,
    )
    # Free-form, but conventionally one of: member_joined / plugin_installed /
    # invitation_accepted / ... — see contract §5.8.
    type: str = Field(max_length=32, index=True)

    family_id: UUID | None = Field(
        default=None,
        foreign_key="families.id",
        ondelete="SET NULL",
        nullable=True,
    )

    title: str = Field(max_length=100)
    body: str = Field(max_length=280)
    icon_emoji: str = Field(default="🔔", max_length=16)
    deeplink: str | None = Field(default=None, max_length=200)

    read_at: datetime | None = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True),
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class NotificationRead(BaseModel):
    """Public shape — matches contract §5.8 example."""

    id: UUID
    type: str
    family_id: UUID | None
    title: str
    body: str
    icon_emoji: str
    deeplink: str | None
    read_at: datetime | None
    created_at: datetime
