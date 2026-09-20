"""支持订阅自动记账的分类和预算设置，旧订阅保留原行为。"""

import sqlalchemy as sa
from alembic import op

revision = "f2a3b4c5d6e7"
down_revision = "e1f2a3b4c5d6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "subscription_items",
        sa.Column("accounting_category", sa.String(16), nullable=False, server_default="subscription"),
    )
    op.add_column(
        "subscription_items",
        sa.Column("exclude_from_budget", sa.Boolean(), nullable=False, server_default=sa.false()),
    )


def downgrade() -> None:
    op.drop_column("subscription_items", "exclude_from_budget")
    op.drop_column("subscription_items", "accounting_category")
