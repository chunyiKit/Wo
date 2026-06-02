"""p27 plant log multi-photo

Adds plant_logs.photos (JSON list of {key, content_type}) so a care log can hold
several photos that the AI analyzes together. The legacy single photo_storage_key
columns stay (mirror the first photo) for the cover/thumbnail/back-compat.

Revision ID: f9a0b1c2d3e4
Revises: e8f9a0b1c2d3
Create Date: 2026-06-01 12:30:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'f9a0b1c2d3e4'
down_revision: str | None = 'e8f9a0b1c2d3'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('plant_logs', sa.Column('photos', sa.JSON(), nullable=True))


def downgrade() -> None:
    op.drop_column('plant_logs', 'photos')
