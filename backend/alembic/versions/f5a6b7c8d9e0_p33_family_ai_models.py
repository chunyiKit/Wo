"""p33 family ai models

Per-family AI model configuration (replaces the global static kimi_* config):
one row per (family, ai_type) holding the model service + an encrypted API key.
ai_type is the capability a plugin requests — multimodal / text / image / video.

Revision ID: f5a6b7c8d9e0
Revises: e3f4a5b6c7d8
Create Date: 2026-06-08 14:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "f5a6b7c8d9e0"
down_revision: str | None = "e3f4a5b6c7d8"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "family_ai_models",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("ai_type", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("label", sqlmodel.sql.sqltypes.AutoString(length=40), nullable=False),
        sa.Column("base_url", sqlmodel.sql.sqltypes.AutoString(length=255), nullable=False),
        sa.Column("model", sqlmodel.sql.sqltypes.AutoString(length=80), nullable=False),
        sa.Column("api_key_encrypted", sa.Text(), nullable=False),
        sa.Column("key_hint", sqlmodel.sql.sqltypes.AutoString(length=8), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_by", sa.Uuid(), nullable=True),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["updated_by"], ["users.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("family_id", "ai_type", name="uq_family_ai_type"),
    )
    op.create_index(
        op.f("ix_family_ai_models_family_id"),
        "family_ai_models",
        ["family_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(
        op.f("ix_family_ai_models_family_id"), table_name="family_ai_models"
    )
    op.drop_table("family_ai_models")
