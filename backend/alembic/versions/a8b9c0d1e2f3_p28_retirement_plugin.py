"""p28 retirement plugin

Creates the 退休倒计时 plugin tables:
- retire_accounts: family financial accounts (deposit / housing fund) with an
  optional fixed monthly income.
- retire_debts: recurring debts (mortgage / car loan) auto-deducted on a day.
- retire_plan: per-family retirement target + calculation-basis toggles.
- retire_ledger: append-only log of automated events (also the idempotency key).

Revision ID: a8b9c0d1e2f3
Revises: f9a0b1c2d3e4
Create Date: 2026-06-02 10:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel
from alembic import op


# revision identifiers, used by Alembic.
revision: str = "a8b9c0d1e2f3"
down_revision: str | None = "f9a0b1c2d3e4"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "retire_accounts",
        sa.Column("name", sqlmodel.sql.sqltypes.AutoString(length=40), nullable=False),
        sa.Column("kind", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("emoji", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("balance", sa.Numeric(precision=14, scale=2), nullable=False),
        sa.Column("monthly_income", sa.Numeric(precision=14, scale=2), nullable=False),
        sa.Column("income_day", sa.Integer(), nullable=False),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_by", sa.Uuid(), nullable=True),
        sa.ForeignKeyConstraint(["created_by"], ["users.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_retire_accounts_family_id"),
        "retire_accounts",
        ["family_id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_retire_accounts_created_at"),
        "retire_accounts",
        ["created_at"],
        unique=False,
    )

    op.create_table(
        "retire_debts",
        sa.Column("name", sqlmodel.sql.sqltypes.AutoString(length=40), nullable=False),
        sa.Column("kind", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("emoji", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("balance", sa.Numeric(precision=14, scale=2), nullable=False),
        sa.Column("monthly_payment", sa.Numeric(precision=14, scale=2), nullable=False),
        sa.Column("payment_day", sa.Integer(), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("from_account_id", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_by", sa.Uuid(), nullable=True),
        sa.ForeignKeyConstraint(["from_account_id"], ["retire_accounts.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["created_by"], ["users.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_retire_debts_family_id"),
        "retire_debts",
        ["family_id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_retire_debts_created_at"),
        "retire_debts",
        ["created_at"],
        unique=False,
    )

    op.create_table(
        "retire_plan",
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("retire_date", sa.Date(), nullable=True),
        sa.Column("savings_goal", sa.Numeric(precision=14, scale=2), nullable=True),
        sa.Column("goal_basis", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column(
            "surplus_basis",
            sqlmodel.sql.sqltypes.AutoString(length=24),
            nullable=False,
        ),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_by", sa.Uuid(), nullable=True),
        sa.ForeignKeyConstraint(["updated_by"], ["users.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("family_id"),
    )

    op.create_table(
        "retire_ledger",
        sa.Column("kind", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("account_id", sa.Uuid(), nullable=True),
        sa.Column("debt_id", sa.Uuid(), nullable=True),
        sa.Column("amount", sa.Numeric(precision=14, scale=2), nullable=False),
        sa.Column("period", sqlmodel.sql.sqltypes.AutoString(length=7), nullable=False),
        sa.Column("note", sqlmodel.sql.sqltypes.AutoString(length=200), nullable=True),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_retire_ledger_family_id"),
        "retire_ledger",
        ["family_id"],
        unique=False,
    )
    op.create_index(op.f("ix_retire_ledger_period"), "retire_ledger", ["period"], unique=False)
    op.create_index(
        op.f("ix_retire_ledger_created_at"),
        "retire_ledger",
        ["created_at"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_retire_ledger_created_at"), table_name="retire_ledger")
    op.drop_index(op.f("ix_retire_ledger_period"), table_name="retire_ledger")
    op.drop_index(op.f("ix_retire_ledger_family_id"), table_name="retire_ledger")
    op.drop_table("retire_ledger")

    op.drop_table("retire_plan")

    op.drop_index(op.f("ix_retire_debts_created_at"), table_name="retire_debts")
    op.drop_index(op.f("ix_retire_debts_family_id"), table_name="retire_debts")
    op.drop_table("retire_debts")

    op.drop_index(op.f("ix_retire_accounts_created_at"), table_name="retire_accounts")
    op.drop_index(op.f("ix_retire_accounts_family_id"), table_name="retire_accounts")
    op.drop_table("retire_accounts")
