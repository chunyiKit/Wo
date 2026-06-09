"""p36 travel ↔ memory link

Adds travel_trips.memory_id — an optional 1:1 link from a travel record to a
memory (回忆). Deleting the memory sets this back to NULL (the trip unlinks).

Revision ID: 9a0b1c2d3e4f
Revises: 7c8d9e0f1a2b
Create Date: 2026-06-09 11:30:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "9a0b1c2d3e4f"
down_revision: str | None = "7c8d9e0f1a2b"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "travel_trips",
        sa.Column("memory_id", sa.Uuid(), nullable=True),
    )
    op.create_index(
        op.f("ix_travel_trips_memory_id"),
        "travel_trips",
        ["memory_id"],
        unique=False,
    )
    op.create_foreign_key(
        "fk_travel_trips_memory_id",
        "travel_trips",
        "memory_memories",
        ["memory_id"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint(
        "fk_travel_trips_memory_id", "travel_trips", type_="foreignkey"
    )
    op.drop_index(op.f("ix_travel_trips_memory_id"), table_name="travel_trips")
    op.drop_column("travel_trips", "memory_id")
