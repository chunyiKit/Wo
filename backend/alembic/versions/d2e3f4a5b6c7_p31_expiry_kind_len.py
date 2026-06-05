"""p31 widen expiry_items.kind to varchar(32)

The `kind` column was created as varchar(16), but the longest built-in kind code
"vehicle_inspection" is 18 chars, so inserting a 车辆年检 item raised
StringDataRightTruncationError → 500 on create. Widen to 32 (metadata-only in
Postgres, no table rewrite).

Revision ID: d2e3f4a5b6c7
Revises: c0d1e2f3a4b5
Create Date: 2026-06-04 12:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "d2e3f4a5b6c7"
down_revision: str | None = "c0d1e2f3a4b5"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column(
        "expiry_items",
        "kind",
        existing_type=sa.String(length=16),
        type_=sa.String(length=32),
        existing_nullable=False,
    )


def downgrade() -> None:
    op.alter_column(
        "expiry_items",
        "kind",
        existing_type=sa.String(length=32),
        type_=sa.String(length=16),
        existing_nullable=False,
    )
