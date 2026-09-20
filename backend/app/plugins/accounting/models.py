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
from secrets import token_hex
from uuid import UUID

from pydantic import field_validator
from sqlalchemy import Column, DateTime, Numeric, UniqueConstraint
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

# 保留内置分类的稳定代码，兼容已有账目和旧客户端。
ALLOWED_CATEGORIES: tuple[str, ...] = (
    "dining",
    "snack",
    "shopping",
    "utilities",
    "car",
    "pet",
    "subscription",
)


class CategoryCreate(SQLModel):
    label: str = Field(min_length=1, max_length=20)
    emoji: str = Field(default="💰", min_length=1, max_length=16)

    @field_validator("label", "emoji", mode="before")
    @classmethod
    def strip_text(cls, value: object) -> object:
        return value.strip() if isinstance(value, str) else value


class CategoryRead(CategoryCreate):
    code: str


class CustomCategory(SQLModel, table=True):
    __tablename__ = "acct_categories"
    __table_args__ = (UniqueConstraint("family_id", "label", name="uq_acct_category_label"),)

    # 与现有账目的 VARCHAR(16) 兼容；代码不依赖用户输入的分类名称。
    code: str = Field(default_factory=lambda: "c_" + token_hex(7), primary_key=True, max_length=16)
    family_id: UUID = Field(foreign_key="families.id", ondelete="CASCADE", index=True)
    label: str = Field(max_length=20)
    emoji: str = Field(max_length=16)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class TransactionBase(SQLModel):
    amount: Decimal = Field(sa_column=Column(Numeric(12, 2), nullable=False))
    category: str = Field(max_length=16)
    note: str | None = Field(default=None, max_length=200)
    # True → 这笔仍计入「本月支出」，但不从月预算中扣除（预算外支出）。
    exclude_from_budget: bool = Field(default=False)


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
    exclude_from_budget: bool | None = None


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
    # 拆分本月支出：预算内（计入预算扣除）+ 预算外（不计入）= month_total。
    # remaining 只扣 budgeted_total。
    budgeted_total: Decimal = Decimal(0)
    excluded_total: Decimal = Decimal(0)
