"""p15 notification prefs

Revision ID: c9d8e7f6a5b4
Revises: b7c1e2d9a4f3
Create Date: 2026-05-27 11:40:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = 'c9d8e7f6a5b4'
down_revision: str | None = 'b7c1e2d9a4f3'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Per-user notification preferences (push layer). server_default backfills
    # existing rows so the NOT NULL holds on a populated table; absent keys are
    # treated as "enabled" by the app, so behaviour is unchanged until a user
    # toggles something off.
    op.add_column(
        'users',
        sa.Column(
            'notification_prefs',
            postgresql.JSONB(astext_type=sa.Text()),
            server_default='{}',
            nullable=False,
        ),
    )


def downgrade() -> None:
    op.drop_column('users', 'notification_prefs')
