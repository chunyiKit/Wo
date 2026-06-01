"""Subscription (订阅管家) plugin tables.

A single resource — `Subscription`: a recurring bill / subscription a family
pays monthly or yearly. The plugin reminds before each due date and, when the
family also has the accounting plugin installed, auto-records the charge as a
`subscription`-category transaction on the due date.

Table is `subscription_items` (plugin-prefixed), mirroring the other plugins.
"""

from datetime import UTC, date, datetime
from decimal import Decimal
from typing import Literal
from uuid import UUID

from sqlalchemy import Column, Date, DateTime, Numeric
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

MAX_NAME_LEN = 40
MAX_NOTE_LEN = 200
MAX_NOTIFY_DAYS_BEFORE = 60

# Billing cadence. Stored as str (SQLModel can't map a Literal to a column);
# the Create/Update schemas constrain it to these values.
Cycle = Literal["monthly", "yearly"]


class SubscriptionBase(SQLModel):
    name: str = Field(max_length=MAX_NAME_LEN)
    emoji: str = Field(default="💳", max_length=16)
    amount: Decimal = Field(sa_column=Column(Numeric(12, 2), nullable=False))
    # one of Cycle — see note above.
    cycle: str = Field(default="monthly", max_length=16)
    # The next date this subscription is charged. The loop advances it one cycle
    # forward each time it falls due.
    next_due: date = Field(sa_column=Column(Date, nullable=False))
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    # Remind `notify_days_before` days before each due date (0 = on the day).
    notify_enabled: bool = Field(default=True)
    notify_days_before: int = Field(default=3, ge=0, le=MAX_NOTIFY_DAYS_BEFORE)
    # When True and the family has the accounting plugin installed, the due-date
    # charge is auto-recorded as a `subscription` transaction.
    auto_record: bool = Field(default=True)
    # Paused subscriptions are neither reminded nor charged.
    active: bool = Field(default=True)


class Subscription(SubscriptionBase, table=True):
    __tablename__ = "subscription_items"

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
    # which due date we last sent a pre-due reminder for …
    last_notified_due: date | None = Field(
        default=None, sa_column=Column(Date, nullable=True)
    )
    # … and which due date we last processed a charge for.
    last_charged_due: date | None = Field(
        default=None, sa_column=Column(Date, nullable=True)
    )


class SubscriptionCreate(SubscriptionBase):
    """POST request body."""

    cycle: Cycle = "monthly"


class SubscriptionUpdate(SQLModel):
    """PUT request body — all fields optional for partial update."""

    name: str | None = Field(default=None, max_length=MAX_NAME_LEN)
    emoji: str | None = Field(default=None, max_length=16)
    amount: Decimal | None = None
    cycle: Cycle | None = None
    next_due: date | None = None
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    notify_enabled: bool | None = None
    notify_days_before: int | None = Field(
        default=None, ge=0, le=MAX_NOTIFY_DAYS_BEFORE
    )
    auto_record: bool | None = None
    active: bool | None = None


class SubscriptionRead(SubscriptionBase):
    id: UUID
    family_id: UUID
    created_at: datetime
    created_by: UUID | None
    # Days from today to next_due (negative = overdue); computed server-side.
    days_until: int = 0
