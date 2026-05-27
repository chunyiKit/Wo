"""p17 stock plugin

Revision ID: 7a1b2c3d4e5f
Revises: 5777670d1df9
Create Date: 2026-05-27 18:00:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel
from alembic import op


# revision identifiers, used by Alembic.
revision: str = '7a1b2c3d4e5f'
down_revision: str | None = '5777670d1df9'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'stock_items',
        sa.Column('name', sqlmodel.sql.sqltypes.AutoString(length=64), nullable=False),
        sa.Column('emoji', sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column('qty', sa.Integer(), nullable=False),
        sa.Column('unit', sqlmodel.sql.sqltypes.AutoString(length=16), nullable=True),
        sa.Column('low_at', sa.Integer(), nullable=True),
        sa.Column('note', sqlmodel.sql.sqltypes.AutoString(length=500), nullable=True),
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('family_id', sa.Uuid(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('created_by', sa.Uuid(), nullable=True),
        sa.ForeignKeyConstraint(['created_by'], ['users.id'], ondelete='SET NULL'),
        sa.ForeignKeyConstraint(['family_id'], ['families.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_stock_items_family_id'), 'stock_items', ['family_id'], unique=False)

    op.create_table(
        'stock_buys',
        sa.Column('name', sqlmodel.sql.sqltypes.AutoString(length=64), nullable=False),
        sa.Column('emoji', sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column('want_qty', sqlmodel.sql.sqltypes.AutoString(length=32), nullable=True),
        sa.Column('note', sqlmodel.sql.sqltypes.AutoString(length=500), nullable=True),
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('family_id', sa.Uuid(), nullable=False),
        sa.Column('stock_item_id', sa.Uuid(), nullable=True),
        sa.Column('bought', sa.Boolean(), nullable=False),
        sa.Column('bought_at', sa.DateTime(timezone=True), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('created_by', sa.Uuid(), nullable=True),
        sa.ForeignKeyConstraint(['created_by'], ['users.id'], ondelete='SET NULL'),
        sa.ForeignKeyConstraint(['family_id'], ['families.id'], ondelete='CASCADE'),
        sa.ForeignKeyConstraint(['stock_item_id'], ['stock_items.id'], ondelete='SET NULL'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_stock_buys_family_id'), 'stock_buys', ['family_id'], unique=False)
    op.create_index(
        op.f('ix_stock_buys_stock_item_id'), 'stock_buys', ['stock_item_id'], unique=False
    )


def downgrade() -> None:
    op.drop_index(op.f('ix_stock_buys_stock_item_id'), table_name='stock_buys')
    op.drop_index(op.f('ix_stock_buys_family_id'), table_name='stock_buys')
    op.drop_table('stock_buys')
    op.drop_index(op.f('ix_stock_items_family_id'), table_name='stock_items')
    op.drop_table('stock_items')
