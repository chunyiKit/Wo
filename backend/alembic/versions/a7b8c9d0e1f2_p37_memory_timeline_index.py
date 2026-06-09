"""p37 memory timeline keyset index

Adds a composite index on memory_memories (family_id, event_date, created_at,
id) so the timeline's keyset pagination — ORDER BY event_date DESC, created_at
DESC, id DESC, filtered by family_id — runs as an index range scan instead of a
sort over the whole family's memories.

Revision ID: a7b8c9d0e1f2
Revises: 9a0b1c2d3e4f
Create Date: 2026-06-09 14:00:00.000000

"""

from collections.abc import Sequence

from alembic import op

revision: str = "a7b8c9d0e1f2"
down_revision: str | None = "9a0b1c2d3e4f"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_index(
        "ix_memory_timeline",
        "memory_memories",
        ["family_id", "event_date", "created_at", "id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_memory_timeline", table_name="memory_memories")
