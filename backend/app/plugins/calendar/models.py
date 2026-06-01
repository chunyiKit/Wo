"""Calendar (家历) plugin tables.

A single resource — `CalendarItem` — that unifies "events" and "todos":

- An item with `event_date` set is scheduled on the calendar; with `start_minute`
  set too it has a specific time-of-day, otherwise it's an all-day item.
- An item with `event_date == None` is an undated todo sitting in the backlog.
- `repeat` (`none` / `daily` / `weekly` / `monthly`) makes a dated item recur.
  Completing a recurring item rolls `event_date` forward to its next occurrence
  rather than marking it permanently done (see routes.complete_item).

The table is named `calendar_items` (plugin-prefixed) to keep plugin tables
visually separable, mirroring `chore_chores` / `movie_movies`.
"""

from datetime import UTC, date, datetime
from typing import Literal
from uuid import UUID

from sqlalchemy import Column, Date, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

MAX_TITLE_LEN = 64
MAX_NOTE_LEN = 500
# Upper bound on how far ahead a reminder may fire — a year covers any cadence.
MAX_NOTIFY_DAYS_BEFORE = 365
MINUTES_PER_DAY = 24 * 60

RepeatRule = Literal["none", "daily", "weekly", "monthly"]


class CalendarItemBase(SQLModel):
    title: str = Field(max_length=MAX_TITLE_LEN)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    emoji: str = Field(default="📅", max_length=16)
    # The day this item happens / is due. None → an undated todo (backlog item).
    event_date: date | None = Field(
        default=None, sa_column=Column(Date, nullable=True)
    )
    # All-day vs timed. Only meaningful when event_date is set.
    all_day: bool = Field(default=True)
    # Minute-of-day (0..1439) for a timed item; None for all-day. Stored as an
    # int to dodge timezone/`time` quirks — the family is in one local zone.
    start_minute: int | None = Field(default=None, ge=0, le=MINUTES_PER_DAY - 1)
    # Recurrence cadence (one of RepeatRule). Stored as str so SQLModel can map
    # it to a column; the Create/Update schemas constrain it to valid values.
    # Only valid when event_date is set (normalized in routes).
    repeat: str = Field(default="none", max_length=16)
    # Due reminder: a notification fires `notify_days_before` days ahead of the
    # next occurrence (0 = on the day). Requires event_date (validated in routes).
    notify_enabled: bool = Field(default=False)
    notify_days_before: int = Field(default=0, ge=0, le=MAX_NOTIFY_DAYS_BEFORE)


class CalendarItem(CalendarItemBase, table=True):
    __tablename__ = "calendar_items"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    # The member responsible. Nullable: an item can sit unassigned. SET NULL on
    # user delete so the item survives a member leaving.
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
    # Which occurrence date we last reminded for. Guards against double-notifying
    # within one occurrence's window; a later occurrence differs, so it re-fires.
    last_notified_occurrence: date | None = Field(
        default=None,
        sa_column=Column(Date, nullable=True),
    )


class CalendarItemCreate(CalendarItemBase):
    """POST request body."""

    repeat: RepeatRule = "none"
    assigned_to: UUID | None = None


class CalendarItemUpdate(SQLModel):
    """PUT request body — all fields optional for partial update.

    `done` is NOT toggled here; use the complete/reopen routes so recurring
    items roll their date forward correctly.
    """

    title: str | None = Field(default=None, max_length=MAX_TITLE_LEN)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    emoji: str | None = Field(default=None, max_length=16)
    event_date: date | None = None
    all_day: bool | None = None
    start_minute: int | None = Field(default=None, ge=0, le=MINUTES_PER_DAY - 1)
    repeat: RepeatRule | None = None
    assigned_to: UUID | None = None
    notify_enabled: bool | None = None
    notify_days_before: int | None = Field(
        default=None, ge=0, le=MAX_NOTIFY_DAYS_BEFORE
    )
    # Sentinel set marks whether the client explicitly sent event_date /
    # assigned_to (so clearing to None is distinguishable from "unchanged").
    # Handled in routes via model_fields_set.


class CalendarItemRead(CalendarItemBase):
    id: UUID
    family_id: UUID
    assigned_to: UUID | None
    done: bool
    completed_at: datetime | None
    created_at: datetime
    created_by: UUID | None
    # The resolved next occurrence (for recurring items, advanced past today;
    # for single dated items, the event_date itself; None for undated todos).
    # Computed server-side so clients don't reimplement recurrence math.
    next_date: date | None = None
    # Days from today to next_date (negative = overdue). None for undated todos.
    days_until: int | None = None
    # Assignee display info, injected from the family's memberships
    # (see service.build_read). Null when unassigned or the member left.
    assignee_name: str | None = None
    assignee_emoji: str | None = None
    # Member-avatar URL when the assignee uploaded a real photo; None → emoji.
    assignee_avatar_url: str | None = None
