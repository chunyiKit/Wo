"""p25 plant plugin

Creates the 植物日记 (plant journal) plugin tables:
- plant_plants:          one plant a family tends (identity, cover, placement,
                         user-set care cycles + next-due dates).
- plant_logs:            dated care entries (photo + AI assessment/advice).
- plant_family_settings: the family's default environment (location), one row
                         per family; new plants inherit it.

Revision ID: d7e8f9a0b1c2
Revises: c6d7e8f9a0b1
Create Date: 2026-06-01 10:00:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'd7e8f9a0b1c2'
down_revision: str | None = 'c6d7e8f9a0b1'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'plant_plants',
        sa.Column('name', sqlmodel.sql.sqltypes.AutoString(length=40), nullable=False),
        sa.Column('emoji', sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column('species', sqlmodel.sql.sqltypes.AutoString(length=60), nullable=True),
        sa.Column(
            'placement', sqlmodel.sql.sqltypes.AutoString(length=24), nullable=False
        ),
        sa.Column('water_interval_days', sa.Integer(), nullable=True),
        sa.Column('fert_interval_days', sa.Integer(), nullable=True),
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('family_id', sa.Uuid(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            'cover_storage_key', sqlmodel.sql.sqltypes.AutoString(), nullable=True
        ),
        sa.Column(
            'cover_content_type', sqlmodel.sql.sqltypes.AutoString(), nullable=True
        ),
        sa.Column('cover_version', sa.Integer(), nullable=False),
        sa.Column('next_water_due', sa.Date(), nullable=True),
        sa.Column('next_fert_due', sa.Date(), nullable=True),
        sa.Column('last_notified_water_due', sa.Date(), nullable=True),
        sa.Column('last_notified_fert_due', sa.Date(), nullable=True),
        sa.ForeignKeyConstraint(['family_id'], ['families.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(
        op.f('ix_plant_plants_family_id'),
        'plant_plants',
        ['family_id'],
        unique=False,
    )

    op.create_table(
        'plant_logs',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('plant_id', sa.Uuid(), nullable=False),
        sa.Column('family_id', sa.Uuid(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            'photo_storage_key', sqlmodel.sql.sqltypes.AutoString(), nullable=True
        ),
        sa.Column(
            'photo_content_type', sqlmodel.sql.sqltypes.AutoString(), nullable=True
        ),
        sa.Column('photo_version', sa.Integer(), nullable=False),
        sa.Column('env_snapshot', sa.JSON(), nullable=True),
        sa.Column('note', sqlmodel.sql.sqltypes.AutoString(length=500), nullable=True),
        sa.Column(
            'ai_status', sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False
        ),
        sa.Column(
            'ai_assessment',
            sqlmodel.sql.sqltypes.AutoString(length=2000),
            nullable=True,
        ),
        sa.Column('ai_advice', sa.JSON(), nullable=True),
        sa.Column('ai_suggested_water_days', sa.Integer(), nullable=True),
        sa.Column('ai_suggested_fert_days', sa.Integer(), nullable=True),
        sa.ForeignKeyConstraint(
            ['plant_id'], ['plant_plants.id'], ondelete='CASCADE'
        ),
        sa.ForeignKeyConstraint(['family_id'], ['families.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(
        op.f('ix_plant_logs_plant_id'), 'plant_logs', ['plant_id'], unique=False
    )
    op.create_index(
        op.f('ix_plant_logs_family_id'), 'plant_logs', ['family_id'], unique=False
    )

    op.create_table(
        'plant_family_settings',
        sa.Column('family_id', sa.Uuid(), nullable=False),
        sa.Column('latitude', sa.Float(), nullable=True),
        sa.Column('longitude', sa.Float(), nullable=True),
        sa.Column(
            'location_label', sqlmodel.sql.sqltypes.AutoString(length=60), nullable=True
        ),
        sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(['family_id'], ['families.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('family_id'),
    )


def downgrade() -> None:
    op.drop_table('plant_family_settings')
    op.drop_index(op.f('ix_plant_logs_family_id'), table_name='plant_logs')
    op.drop_index(op.f('ix_plant_logs_plant_id'), table_name='plant_logs')
    op.drop_table('plant_logs')
    op.drop_index(op.f('ix_plant_plants_family_id'), table_name='plant_plants')
    op.drop_table('plant_plants')
