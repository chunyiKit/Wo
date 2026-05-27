"""p15 chore recurring

Revision ID: c5d6e7f8a9b0
Revises: b7c1e2d9a4f3
Create Date: 2026-05-27 10:00:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'c5d6e7f8a9b0'
down_revision: str | None = 'b7c1e2d9a4f3'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        'chore_chores',
        sa.Column(
            'recurring',
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )
    # Drop the server default once existing rows are backfilled; the ORM supplies
    # the value on every insert from here on.
    op.alter_column('chore_chores', 'recurring', server_default=None)


def downgrade() -> None:
    op.drop_column('chore_chores', 'recurring')
