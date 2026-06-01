"""p22 subscription plugin

Creates subscription_items for the 订阅管家 plugin (recurring bills with due
reminders + auto-record into accounting).

Revision ID: a4b5c6d7e8f9
Revises: f3a4b5c6d7e8
Create Date: 2026-05-29 14:00:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel
from alembic import op


# revision identifiers, used by Alembic.
revision: str = 'a4b5c6d7e8f9'
down_revision: str | None = 'f3a4b5c6d7e8'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'subscription_items',
        sa.Column('name', sqlmodel.sql.sqltypes.AutoString(length=40), nullable=False),
        sa.Column('emoji', sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column('amount', sa.Numeric(precision=12, scale=2), nullable=False),
        sa.Column('cycle', sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column('next_due', sa.Date(), nullable=False),
        sa.Column('note', sqlmodel.sql.sqltypes.AutoString(length=200), nullable=True),
        sa.Column('notify_enabled', sa.Boolean(), nullable=False),
        sa.Column('notify_days_before', sa.Integer(), nullable=False),
        sa.Column('auto_record', sa.Boolean(), nullable=False),
        sa.Column('active', sa.Boolean(), nullable=False),
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('family_id', sa.Uuid(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('created_by', sa.Uuid(), nullable=True),
        sa.Column('last_notified_due', sa.Date(), nullable=True),
        sa.Column('last_charged_due', sa.Date(), nullable=True),
        sa.ForeignKeyConstraint(['created_by'], ['users.id'], ondelete='SET NULL'),
        sa.ForeignKeyConstraint(['family_id'], ['families.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(
        op.f('ix_subscription_items_family_id'),
        'subscription_items',
        ['family_id'],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(
        op.f('ix_subscription_items_family_id'), table_name='subscription_items'
    )
    op.drop_table('subscription_items')
