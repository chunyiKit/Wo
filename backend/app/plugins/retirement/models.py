"""Retirement countdown (退休倒计时) plugin tables.

Four family-shared resources (isolation key = `family_id`):

- `RetireAccount` (`retire_accounts`): a financial account — deposit (存款) or
  housing fund (公积金) — with a balance and an optional fixed monthly income
  that auto-credits on the account's `income_day`.
- `RetireDebt` (`retire_debts`): a recurring debt (mortgage / car loan / …)
  whose `monthly_payment` auto-deducts on `payment_day`, shrinking both the
  debt and (when linked) a deposit account.
- `RetirePlan` (`retire_plan`): one row per family — the retirement target
  (date + savings goal) plus two calculation-basis toggles.
- `RetireLedger` (`retire_ledger`): an append-only log of every automated event
  (income credit / debt payment / month-end expense settle). It doubles as the
  idempotency guard — an event for a given (period, kind, account/debt) is
  applied at most once (mirrors how the accounting reminder dedupes via the
  notifications table, so no extra marker columns are needed).
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
MAX_DAY = 28  # cap monthly day-of-month so it lands every month (no 29/30/31)

# Stored as str (SQLModel can't map a Literal to a column); the Create/Update
# schemas constrain them to these values, and the routes validate on write.
AccountKind = Literal["deposit", "fund"]
ACCOUNT_KINDS: tuple[str, ...] = ("deposit", "fund")

DebtKind = Literal["mortgage", "car", "other"]
DEBT_KINDS: tuple[str, ...] = ("mortgage", "car", "other")

# What the savings goal's "current progress" is measured against.
GoalBasis = Literal["net_worth", "total_assets", "deposit_only"]
GOAL_BASES: tuple[str, ...] = ("net_worth", "total_assets", "deposit_only")

# How the monthly net surplus (used for the projection) is composed.
SurplusBasis = Literal["income_debt_expense", "income_debt", "income_only"]
SURPLUS_BASES: tuple[str, ...] = ("income_debt_expense", "income_debt", "income_only")

LedgerKind = Literal["income", "debt_payment", "expense_settle"]
LEDGER_KINDS: tuple[str, ...] = ("income", "debt_payment", "expense_settle")


def _money_col(*, nullable: bool = False) -> Column:
    """A fresh Numeric(14,2) column (called per-field — never share a Column)."""
    return Column(Numeric(14, 2), nullable=nullable)


# ── Accounts ────────────────────────────────────────────────────────────────


class RetireAccountBase(SQLModel):
    name: str = Field(max_length=MAX_NAME_LEN)
    # one of AccountKind — see note above.
    kind: str = Field(default="deposit", max_length=16)
    emoji: str = Field(default="🏦", max_length=16)
    balance: Decimal = Field(sa_column=_money_col())
    # Fixed income credited to this account every month on `income_day` (0 = no
    # recurring income). Both deposit and fund accounts may have one.
    monthly_income: Decimal = Field(default=Decimal("0"), sa_column=_money_col())
    income_day: int = Field(default=1, ge=1, le=MAX_DAY)


class RetireAccount(RetireAccountBase, table=True):
    __tablename__ = "retire_accounts"

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


class RetireAccountCreate(RetireAccountBase):
    """POST request body."""

    kind: AccountKind = "deposit"


class RetireAccountUpdate(SQLModel):
    """PUT request body — all fields optional for partial update."""

    name: str | None = Field(default=None, max_length=MAX_NAME_LEN)
    kind: AccountKind | None = None
    emoji: str | None = Field(default=None, max_length=16)
    balance: Decimal | None = None
    monthly_income: Decimal | None = None
    income_day: int | None = Field(default=None, ge=1, le=MAX_DAY)


class RetireAccountRead(RetireAccountBase):
    id: UUID
    family_id: UUID
    created_at: datetime
    created_by: UUID | None
    # Creator display info, injected server-side (see CLAUDE.md avatar rule).
    creator_name: str | None = None
    creator_emoji: str | None = None
    creator_avatar_url: str | None = None


# ── Debts ─────────────────────────────────────────────────────────────────────


class RetireDebtBase(SQLModel):
    name: str = Field(max_length=MAX_NAME_LEN)
    # one of DebtKind — see note above.
    kind: str = Field(default="mortgage", max_length=16)
    emoji: str = Field(default="🏠", max_length=16)
    # Remaining balance owed; shrinks by `monthly_payment` on each payment_day.
    balance: Decimal = Field(sa_column=_money_col())
    monthly_payment: Decimal = Field(sa_column=_money_col())
    payment_day: int = Field(default=1, ge=1, le=MAX_DAY)
    # Paused debts are neither charged nor counted as monthly debt outflow.
    active: bool = Field(default=True)


class RetireDebt(RetireDebtBase, table=True):
    __tablename__ = "retire_debts"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    # Which deposit account the payment is drawn from. Null = track the debt
    # only, don't touch any account balance. SET NULL if that account is deleted.
    from_account_id: UUID | None = Field(
        default=None,
        foreign_key="retire_accounts.id",
        ondelete="SET NULL",
        nullable=True,
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


class RetireDebtCreate(RetireDebtBase):
    """POST request body."""

    kind: DebtKind = "mortgage"
    from_account_id: UUID | None = None


class RetireDebtUpdate(SQLModel):
    """PUT request body — all fields optional for partial update."""

    name: str | None = Field(default=None, max_length=MAX_NAME_LEN)
    kind: DebtKind | None = None
    emoji: str | None = Field(default=None, max_length=16)
    balance: Decimal | None = None
    monthly_payment: Decimal | None = None
    payment_day: int | None = Field(default=None, ge=1, le=MAX_DAY)
    from_account_id: UUID | None = None
    active: bool | None = None


class RetireDebtRead(RetireDebtBase):
    id: UUID
    family_id: UUID
    from_account_id: UUID | None = None
    created_at: datetime
    created_by: UUID | None
    creator_name: str | None = None
    creator_emoji: str | None = None
    creator_avatar_url: str | None = None


# ── Plan (one row per family) ─────────────────────────────────────────────────


class RetirePlan(SQLModel, table=True):
    __tablename__ = "retire_plan"

    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        primary_key=True,
    )
    retire_date: date | None = Field(default=None, sa_column=Column(Date, nullable=True))
    savings_goal: Decimal | None = Field(default=None, sa_column=_money_col(nullable=True))
    # one of GoalBasis / SurplusBasis — see notes above.
    goal_basis: str = Field(default="net_worth", max_length=16)
    surplus_basis: str = Field(default="income_debt_expense", max_length=24)
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


class RetirePlanUpdate(SQLModel):
    """PUT request body — set/clear the retirement target + calculation bases."""

    retire_date: date | None = None
    savings_goal: Decimal | None = None
    goal_basis: GoalBasis | None = None
    surplus_basis: SurplusBasis | None = None


class RetirePlanRead(SQLModel):
    retire_date: date | None = None
    savings_goal: Decimal | None = None
    goal_basis: str = "net_worth"
    surplus_basis: str = "income_debt_expense"


# ── Ledger (append-only automated-event log) ──────────────────────────────────


class RetireLedger(SQLModel, table=True):
    __tablename__ = "retire_ledger"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    # one of LedgerKind — see note above.
    kind: str = Field(max_length=16)
    account_id: UUID | None = Field(default=None, nullable=True)
    debt_id: UUID | None = Field(default=None, nullable=True)
    amount: Decimal = Field(sa_column=_money_col())
    # The calendar month this event belongs to, "YYYY-MM"; the idempotency key.
    period: str = Field(max_length=7, index=True)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False, index=True),
    )


class RetireLedgerRead(SQLModel):
    id: UUID
    kind: str
    account_id: UUID | None
    debt_id: UUID | None
    amount: Decimal
    period: str
    note: str | None
    created_at: datetime


# ── Dashboard (computed, read-only) ───────────────────────────────────────────


class RetireDashboardRead(SQLModel):
    """The computed retirement picture surfaced on the overview tab."""

    # Balances.
    total_deposit: Decimal
    total_fund: Decimal
    total_assets: Decimal
    total_debt: Decimal
    net_worth: Decimal
    # The figure compared against the goal, per the family's goal_basis.
    current: Decimal

    # Monthly flows.
    monthly_income: Decimal
    monthly_debt: Decimal
    monthly_expense: Decimal
    monthly_surplus: Decimal

    # Plan + projection (None until retire_date / savings_goal are set).
    retire_date: date | None = None
    savings_goal: Decimal | None = None
    goal_basis: str = "net_worth"
    surplus_basis: str = "income_debt_expense"
    days_to_retire: int | None = None
    months_to_retire: int | None = None
    goal_reached: bool = False
    remaining: Decimal | None = None
    # Requirement 6: months to reach the goal at the current surplus rate;
    # None = unreachable (surplus ≤ 0 and not yet reached).
    months_to_goal: int | None = None
    # The monthly surplus needed to hit the goal exactly by retire_date.
    required_monthly: Decimal | None = None
    # Requirement 7: surplus − required_monthly. > 0 → on track with a cushion
    # (client shows +¥ in red); < 0 → income must rise by |gap| (client shows
    # −¥ in green). None when it can't be computed (no plan / retire date past).
    monthly_gap: Decimal | None = None

    accounting_installed: bool = False
