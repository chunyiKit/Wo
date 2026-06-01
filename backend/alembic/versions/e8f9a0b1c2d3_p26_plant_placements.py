"""p26 plant family-shared placement presets

Adds plant_family_settings.placements (JSON list of strings) so a family's
placement labels are shared across members instead of living on one device.

Revision ID: e8f9a0b1c2d3
Revises: d7e8f9a0b1c2
Create Date: 2026-06-01 11:00:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'e8f9a0b1c2d3'
down_revision: str | None = 'd7e8f9a0b1c2'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        'plant_family_settings',
        sa.Column('placements', sa.JSON(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column('plant_family_settings', 'placements')
