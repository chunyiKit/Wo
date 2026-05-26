"""p9_anniversary_reminders

Adds due-date reminder fields to anniv_dates: an on/off switch, how many days
ahead to notify, and a per-occurrence idempotency marker.

Revision ID: e5f6a7b8c9d0
Revises: d4e5f6a7b8c9
Create Date: 2026-05-25 21:30:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op


# revision identifiers, used by Alembic.
revision: str = 'e5f6a7b8c9d0'
down_revision: str | None = 'd4e5f6a7b8c9'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        'anniv_dates',
        sa.Column(
            'notify_enabled', sa.Boolean(), nullable=False, server_default=sa.false()
        ),
    )
    op.add_column(
        'anniv_dates',
        sa.Column(
            'notify_days_before', sa.Integer(), nullable=False, server_default='0'
        ),
    )
    op.add_column(
        'anniv_dates',
        sa.Column('last_notified_event_date', sa.Date(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column('anniv_dates', 'last_notified_event_date')
    op.drop_column('anniv_dates', 'notify_days_before')
    op.drop_column('anniv_dates', 'notify_enabled')
