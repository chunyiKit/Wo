"""新增家庭共享的记账自定义分类。"""

import sqlalchemy as sa
from alembic import op

revision = "e1f2a3b4c5d6"
down_revision = "d0e1f2a3b4c5"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "acct_categories",
        sa.Column("code", sa.String(16), primary_key=True),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("label", sa.String(20), nullable=False),
        sa.Column("emoji", sa.String(16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("family_id", "label", name="uq_acct_category_label"),
    )
    op.create_index("ix_acct_categories_family_id", "acct_categories", ["family_id"])


def downgrade() -> None:
    op.drop_table("acct_categories")
