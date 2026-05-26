"""p14 user avatar

Revision ID: b7c1e2d9a4f3
Revises: fa8d5352ec93
Create Date: 2026-05-26 22:10:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel
from alembic import op


# revision identifiers, used by Alembic.
revision: str = 'b7c1e2d9a4f3'
down_revision: str | None = 'fa8d5352ec93'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('users', sa.Column('avatar_storage_key', sqlmodel.sql.sqltypes.AutoString(length=255), nullable=True))
    op.add_column('users', sa.Column('avatar_content_type', sqlmodel.sql.sqltypes.AutoString(length=64), nullable=True))
    # server_default backfills existing rows (NOT NULL on a populated table).
    op.add_column('users', sa.Column('avatar_version', sa.Integer(), nullable=False, server_default='0'))


def downgrade() -> None:
    op.drop_column('users', 'avatar_version')
    op.drop_column('users', 'avatar_content_type')
    op.drop_column('users', 'avatar_storage_key')
