"""Anniversary plugin tables.

A single resource — `Anniversary` (date entries belonging to a family). The
table is named `anniv_dates` (plugin-prefixed) to keep plugin tables visually
separable in PG.
"""

from datetime import UTC, date, datetime
from uuid import UUID

from sqlalchemy import Column, Date, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

# Upper bound on how far ahead a reminder may fire — a year covers any cadence.
MAX_NOTIFY_DAYS_BEFORE = 365


class AnniversaryBase(SQLModel):
    # NOTE: field is `event_date`, not `date`, to avoid clashing with the
    # imported `datetime.date` type name in pydantic v2's annotation parser.
    name: str = Field(max_length=32)
    event_date: date = Field(sa_column=Column(Date, nullable=False))
    emoji: str = Field(default="💞", max_length=16)
    is_lunar: bool = Field(default=False)
    note: str | None = Field(default=None, max_length=200)
    # Due-date reminder: when on, a notification fires `notify_days_before` days
    # ahead of each occurrence (0 = on the day itself). See plugins/.../reminders.
    notify_enabled: bool = Field(default=False)
    notify_days_before: int = Field(default=0, ge=0, le=MAX_NOTIFY_DAYS_BEFORE)


class Anniversary(AnniversaryBase, table=True):
    __tablename__ = "anniv_dates"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
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
    # Which occurrence date we last sent a reminder for. Guards against double
    # notifying within one occurrence's window; a new year's occurrence differs,
    # so the next anniversary fires again. Internal — not exposed in reads.
    last_notified_event_date: date | None = Field(
        default=None,
        sa_column=Column(Date, nullable=True),
    )


class AnniversaryCreate(AnniversaryBase):
    """POST request body."""


class AnniversaryUpdate(SQLModel):
    """PUT request body — all fields optional for partial update."""

    name: str | None = Field(default=None, max_length=32)
    event_date: date | None = None
    emoji: str | None = Field(default=None, max_length=16)
    is_lunar: bool | None = None
    note: str | None = Field(default=None, max_length=200)
    notify_enabled: bool | None = None
    notify_days_before: int | None = Field(
        default=None, ge=0, le=MAX_NOTIFY_DAYS_BEFORE
    )


class AnniversaryRead(AnniversaryBase):
    id: UUID
    family_id: UUID
    created_at: datetime
    created_by: UUID | None
    # Days from today to the next occurrence (lunar-aware); computed server-side
    # so clients don't reimplement the calendar math. See service.days_until.
    days_until: int = 0
