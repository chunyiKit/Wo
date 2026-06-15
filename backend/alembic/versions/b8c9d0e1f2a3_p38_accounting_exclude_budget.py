"""p38 accounting exclude_from_budget

Adds acct_transactions.exclude_from_budget — when true the expense still counts
toward 本月支出 but is not deducted from the monthly budget (预算外支出). Existing
rows default to false (counted against the budget, as before).

Revision ID: b8c9d0e1f2a3
Revises: a7b8c9d0e1f2
Create Date: 2026-06-15 10:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "b8c9d0e1f2a3"
down_revision: str | None = "a7b8c9d0e1f2"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "acct_transactions",
        sa.Column(
            "exclude_from_budget",
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )


def downgrade() -> None:
    op.drop_column("acct_transactions", "exclude_from_budget")
