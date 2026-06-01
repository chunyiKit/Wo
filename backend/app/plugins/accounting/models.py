"""Accounting plugin tables.

Two resources:
- `Transaction` (table `acct_transactions`): one expense entry in a family.
- `Budget` (table `acct_budgets`): a family's single recurring monthly budget
  (one row per family, keyed by `family_id`).

Expenses are family-shared: every member sees the whole family's entries, so the
isolation key is `family_id` (who recorded it lives in `created_by`).
"""

from datetime import UTC, datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import Column, DateTime, Numeric
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

# Built-in expense tags. Labels/emoji live on the client; the backend only
# stores and validates these stable codes.
ALLOWED_CATEGORIES: tuple[str, ...] = (
    "dining",
    "snack",
    "shopping",
    "utilities",
    "car",
    "subscription",
)


class TransactionBase(SQLModel):
    amount: Decimal = Field(sa_column=Column(Numeric(12, 2), nullable=False))
    category: str = Field(max_length=16)
    note: str | None = Field(default=None, max_length=200)


class Transaction(TransactionBase, table=True):
    __tablename__ = "acct_transactions"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False, index=True),
    )
    created_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )


class TransactionCreate(TransactionBase):
    """POST request body."""


class TransactionUpdate(SQLModel):
    """PUT request body — all fields optional for partial update."""

    amount: Decimal | None = None
    category: str | None = Field(default=None, max_length=16)
    note: str | None = Field(default=None, max_length=200)


class TransactionRead(TransactionBase):
    id: UUID
    family_id: UUID
    created_at: datetime
    created_by: UUID | None
    # Recorder display info, injected server-side from the family's memberships
    # so the timeline can render avatar + name without an extra round-trip.
    creator_name: str | None = None
    creator_emoji: str | None = None
    # Member-avatar URL when the recorder uploaded a real photo; None → emoji.
    creator_avatar_url: str | None = None


class Budget(SQLModel, table=True):
    __tablename__ = "acct_budgets"

    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        primary_key=True,
    )
    monthly_amount: Decimal = Field(sa_column=Column(Numeric(12, 2), nullable=False))
    updated_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    updated_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )


class BudgetUpdate(SQLModel):
    """PUT request body — set the recurring monthly budget."""

    monthly_amount: Decimal


class BudgetRead(SQLModel):
    monthly_amount: Decimal | None = None


class SummaryRead(SQLModel):
    month_total: Decimal
    budget: Decimal | None = None
    remaining: Decimal | None = None
