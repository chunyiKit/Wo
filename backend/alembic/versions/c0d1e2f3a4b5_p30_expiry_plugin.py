"""p30 expiry plugin

Creates the 到期管家 plugin table:
- expiry_items: things that expire on a date (证件 / 年检 / 保险 / 合同 …) with a
  per-item pre-expiry reminder lead time. Two dedup columns track which expiry
  date the pre-expiry and overdue notices were last sent for.

Revision ID: c0d1e2f3a4b5
Revises: b9c0d1e2f3a4
Create Date: 2026-06-04 10:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "c0d1e2f3a4b5"
down_revision: str | None = "b9c0d1e2f3a4"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "expiry_items",
        sa.Column("name", sqlmodel.sql.sqltypes.AutoString(length=40), nullable=False),
        sa.Column("emoji", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("kind", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("expire_on", sa.Date(), nullable=False),
        sa.Column("note", sqlmodel.sql.sqltypes.AutoString(length=200), nullable=True),
        sa.Column("notify_enabled", sa.Boolean(), nullable=False),
        sa.Column("notify_days_before", sa.Integer(), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_by", sa.Uuid(), nullable=True),
        sa.Column("last_pre_notified_on", sa.Date(), nullable=True),
        sa.Column("last_expired_notified_on", sa.Date(), nullable=True),
        sa.ForeignKeyConstraint(["created_by"], ["users.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_expiry_items_family_id"),
        "expiry_items",
        ["family_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_expiry_items_family_id"), table_name="expiry_items")
    op.drop_table("expiry_items")
