"""p5_user_phone

Adds the `phone` login identifier to users (nullable + unique) and backfills
the three seed users so they remain loginable via POST /auth/login.

Revision ID: a1b2c3d4e5f6
Revises: 60be78b8af24
Create Date: 2026-05-24 09:00:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel
from alembic import op

# revision identifiers, used by Alembic.
revision: str = 'a1b2c3d4e5f6'
down_revision: str | None = '60be78b8af24'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


# (seed user id, phone) — matches app/core/ids.py + app/core/seed.py.
_SEED_PHONES = (
    ('019000a0-1100-7000-8000-000000000001', '13800000001'),
    ('019000a0-1100-7000-8000-000000000002', '13800000002'),
    ('019000a0-1100-7000-8000-000000000003', '13800000003'),
)


def upgrade() -> None:
    op.add_column(
        'users',
        sa.Column('phone', sqlmodel.sql.sqltypes.AutoString(length=20), nullable=True),
    )
    op.create_index(op.f('ix_users_phone'), 'users', ['phone'], unique=True)
    # Backfill already-deployed seed rows (skip rows that don't exist yet).
    # Cast the id param to uuid — the column is uuid, the bind param is text.
    for user_id, phone in _SEED_PHONES:
        op.execute(
            sa.text(
                "UPDATE users SET phone = :phone "
                "WHERE id = CAST(:id AS uuid) AND phone IS NULL"
            ).bindparams(phone=phone, id=user_id)
        )


def downgrade() -> None:
    op.drop_index(op.f('ix_users_phone'), table_name='users')
    op.drop_column('users', 'phone')
