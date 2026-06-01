"""p20 calendar plugin

Revision ID: e2f3a4b5c6d7
Revises: d1e2f3a4b5c6
Create Date: 2026-05-29 09:00:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel
from alembic import op


# revision identifiers, used by Alembic.
revision: str = 'e2f3a4b5c6d7'
down_revision: str | None = 'd1e2f3a4b5c6'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'calendar_items',
        sa.Column('title', sqlmodel.sql.sqltypes.AutoString(length=64), nullable=False),
        sa.Column('note', sqlmodel.sql.sqltypes.AutoString(length=500), nullable=True),
        sa.Column('emoji', sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column('event_date', sa.Date(), nullable=True),
        sa.Column('all_day', sa.Boolean(), nullable=False),
        sa.Column('start_minute', sa.Integer(), nullable=True),
        sa.Column('repeat', sqlmodel.sql.sqltypes.AutoString(), nullable=False),
        sa.Column('notify_enabled', sa.Boolean(), nullable=False),
        sa.Column('notify_days_before', sa.Integer(), nullable=False),
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('family_id', sa.Uuid(), nullable=False),
        sa.Column('assigned_to', sa.Uuid(), nullable=True),
        sa.Column('done', sa.Boolean(), nullable=False),
        sa.Column('completed_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('created_by', sa.Uuid(), nullable=True),
        sa.Column('last_notified_occurrence', sa.Date(), nullable=True),
        sa.ForeignKeyConstraint(['assigned_to'], ['users.id'], ondelete='SET NULL'),
        sa.ForeignKeyConstraint(['created_by'], ['users.id'], ondelete='SET NULL'),
        sa.ForeignKeyConstraint(['family_id'], ['families.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(
        op.f('ix_calendar_items_family_id'),
        'calendar_items',
        ['family_id'],
        unique=False,
    )
    op.create_index(
        op.f('ix_calendar_items_assigned_to'),
        'calendar_items',
        ['assigned_to'],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(op.f('ix_calendar_items_assigned_to'), table_name='calendar_items')
    op.drop_index(op.f('ix_calendar_items_family_id'), table_name='calendar_items')
    op.drop_table('calendar_items')
