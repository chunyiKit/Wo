"""Chore plugin tables.

A single resource — `Chore` (a household task belonging to a family). The table
is named `chore_chores` (plugin-prefixed) to keep plugin tables visually
separable, mirroring `recipe_recipes`.

A chore can be assigned to one family member (`assigned_to`) and toggled between
done / not-done. The home card shows the viewer how many chores are still on
their plate.
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import Column, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

MAX_TITLE_LEN = 64
MAX_NOTE_LEN = 500


class ChoreBase(SQLModel):
    title: str = Field(max_length=MAX_TITLE_LEN)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    emoji: str = Field(default="🧹", max_length=16)


class Chore(ChoreBase, table=True):
    __tablename__ = "chore_chores"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    # The member responsible. Nullable: a chore can sit unassigned until someone
    # picks it up. SET NULL on user delete so the chore survives a member leaving.
    assigned_to: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
        index=True,
    )
    done: bool = Field(default=False)
    completed_at: datetime | None = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True),
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    created_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )


class ChoreCreate(ChoreBase):
    """POST request body."""

    assigned_to: UUID | None = None


class ChoreUpdate(SQLModel):
    """PUT request body — all fields optional for partial update."""

    title: str | None = Field(default=None, max_length=MAX_TITLE_LEN)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    emoji: str | None = Field(default=None, max_length=16)
    assigned_to: UUID | None = None
    done: bool | None = None


class ChoreRead(ChoreBase):
    id: UUID
    family_id: UUID
    assigned_to: UUID | None
    done: bool
    completed_at: datetime | None
    created_at: datetime
    created_by: UUID | None
    # Assignee display info, injected server-side from the family's memberships
    # (see service.build_read). Null when unassigned or the member left.
    assignee_name: str | None = None
    assignee_emoji: str | None = None
    # Member-avatar URL when the assignee uploaded a real photo; None → emoji.
    assignee_avatar_url: str | None = None
