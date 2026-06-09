"""p35 travel place + ai_status

Adds travel_trips.place (optional specific spot, e.g. 长江大桥) and ai_status
(generating | ready | failed) for the new background-generation flow. Existing
rows already have images, so they default to ai_status='ready'.

Revision ID: 7c8d9e0f1a2b
Revises: 8fc2957c819d
Create Date: 2026-06-09 16:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel
from alembic import op

revision: str = "7c8d9e0f1a2b"
down_revision: str | None = "8fc2957c819d"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "travel_trips",
        sa.Column("place", sqlmodel.sql.sqltypes.AutoString(length=60), nullable=True),
    )
    op.add_column(
        "travel_trips",
        sa.Column(
            "ai_status",
            sqlmodel.sql.sqltypes.AutoString(length=16),
            nullable=False,
            server_default="ready",
        ),
    )


def downgrade() -> None:
    op.drop_column("travel_trips", "ai_status")
    op.drop_column("travel_trips", "place")
