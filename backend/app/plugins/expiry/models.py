"""Expiry (到期管家) plugin tables.

A single resource — `ExpiryItem`: something that expires on a date and the
family wants reminding before it does. The reminder loop fires once when the
item enters its pre-expiry window and once when it goes overdue; it never
auto-advances the date (a passport can't auto-renew — the user edits the new
date after renewing).

Table is `expiry_items` (plugin-prefixed), mirroring the other plugins.
"""

from datetime import UTC, date, datetime
from typing import Literal
from uuid import UUID

from sqlalchemy import Column, Date, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

MAX_NAME_LEN = 40
MAX_NOTE_LEN = 200
# Wide enough for the longest built-in kind code ("vehicle_inspection" = 18).
# Was 16, which truncated that code and 500'd on insert — keep margin for new
# kinds.
MAX_KIND_LEN = 32
# Certificates need long lead times (renew a passport months ahead), so allow
# up to a year of advance notice.
MAX_NOTIFY_DAYS_BEFORE = 365

# Built-in item kinds. Labels/emoji live on the client; the backend only stores
# and validates these stable codes. `other` is the catch-all.
Kind = Literal[
    "id_card",
    "passport",
    "visa",
    "driver_license",
    "vehicle_inspection",
    "insurance",
    "contract",
    "membership",
    "household",
    "other",
]
ALLOWED_KINDS: tuple[str, ...] = (
    "id_card",
    "passport",
    "visa",
    "driver_license",
    "vehicle_inspection",
    "insurance",
    "contract",
    "membership",
    "household",
    "other",
)


class ExpiryItemBase(SQLModel):
    name: str = Field(max_length=MAX_NAME_LEN)
    emoji: str = Field(default="📄", max_length=16)
    # one of Kind — stored as str (SQLModel can't map a Literal to a column);
    # the Create/Update schemas constrain it.
    kind: str = Field(default="other", max_length=MAX_KIND_LEN)
    # The date this item expires.
    expire_on: date = Field(sa_column=Column(Date, nullable=False))
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    # Remind `notify_days_before` days before the expiry date (0 = on the day).
    notify_enabled: bool = Field(default=True)
    notify_days_before: int = Field(default=30, ge=0, le=MAX_NOTIFY_DAYS_BEFORE)
    # Archived/handled items are neither reminded nor surfaced on the card.
    active: bool = Field(default=True)


class ExpiryItem(ExpiryItemBase, table=True):
    __tablename__ = "expiry_items"

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
    # Dedup guards (internal, not exposed in reads):
    # which expiry date we last sent a pre-expiry reminder for …
    last_pre_notified_on: date | None = Field(default=None, sa_column=Column(Date, nullable=True))
    # … and which expiry date we last sent the overdue notice for. Both reset
    # to None when the date is edited, so a renewed item re-arms.
    last_expired_notified_on: date | None = Field(
        default=None, sa_column=Column(Date, nullable=True)
    )


class ExpiryItemCreate(ExpiryItemBase):
    """POST request body."""

    kind: Kind = "other"


class ExpiryItemUpdate(SQLModel):
    """PUT request body — all fields optional for partial update."""

    name: str | None = Field(default=None, max_length=MAX_NAME_LEN)
    emoji: str | None = Field(default=None, max_length=16)
    kind: Kind | None = None
    expire_on: date | None = None
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    notify_enabled: bool | None = None
    notify_days_before: int | None = Field(default=None, ge=0, le=MAX_NOTIFY_DAYS_BEFORE)
    active: bool | None = None


class ExpiryItemRead(ExpiryItemBase):
    id: UUID
    family_id: UUID
    created_at: datetime
    created_by: UUID | None
    # Days from today to expire_on (negative = overdue); computed server-side.
    days_until: int = 0
