"""p39 chat plugin

Revision ID: c9d0e1f2a3b4
Revises: b8c9d0e1f2a3
Create Date: 2026-06-25 10:00:00.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa
import sqlmodel

from alembic import op

revision: str = "c9d0e1f2a3b4"
down_revision: str | None = "b8c9d0e1f2a3"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "chat_messages",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("sender_id", sa.Uuid(), nullable=True),
        sa.Column("client_id", sqlmodel.sql.sqltypes.AutoString(length=80), nullable=False),
        sa.Column("kind", sqlmodel.sql.sqltypes.AutoString(length=8), nullable=False),
        sa.Column("body", sqlmodel.sql.sqltypes.AutoString(length=2000), nullable=True),
        sa.Column("sender_name", sqlmodel.sql.sqltypes.AutoString(length=24), nullable=False),
        sa.Column("sender_emoji", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["sender_id"], ["users.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "family_id",
            "sender_id",
            "client_id",
            name="uq_chat_messages_family_sender_client",
        ),
    )
    op.create_index(op.f("ix_chat_messages_family_id"), "chat_messages", ["family_id"])
    op.create_index(op.f("ix_chat_messages_sender_id"), "chat_messages", ["sender_id"])
    op.create_index(
        "ix_chat_messages_family_created_id",
        "chat_messages",
        ["family_id", "created_at", "id"],
    )

    op.create_table(
        "chat_images",
        sa.Column("message_id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("storage_key", sqlmodel.sql.sqltypes.AutoString(length=255), nullable=False),
        sa.Column("content_type", sqlmodel.sql.sqltypes.AutoString(length=64), nullable=False),
        sa.Column("size_bytes", sa.Integer(), nullable=False),
        sa.Column("width", sa.Integer(), nullable=True),
        sa.Column("height", sa.Integer(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["message_id"], ["chat_messages.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("message_id"),
    )
    op.create_index(op.f("ix_chat_images_family_id"), "chat_images", ["family_id"])

    op.create_table(
        "chat_push_outbox",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("message_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("status", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("last_error", sqlmodel.sql.sqltypes.AutoString(length=500), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("sent_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["message_id"], ["chat_messages.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_chat_push_outbox_status_created",
        "chat_push_outbox",
        ["status", "created_at"],
    )
    op.create_index(
        op.f("ix_chat_push_outbox_message_id"),
        "chat_push_outbox",
        ["message_id"],
    )
    op.create_index(op.f("ix_chat_push_outbox_user_id"), "chat_push_outbox", ["user_id"])


def downgrade() -> None:
    op.drop_index(op.f("ix_chat_push_outbox_user_id"), table_name="chat_push_outbox")
    op.drop_index(op.f("ix_chat_push_outbox_message_id"), table_name="chat_push_outbox")
    op.drop_index("ix_chat_push_outbox_status_created", table_name="chat_push_outbox")
    op.drop_table("chat_push_outbox")
    op.drop_index(op.f("ix_chat_images_family_id"), table_name="chat_images")
    op.drop_table("chat_images")
    op.drop_index("ix_chat_messages_family_created_id", table_name="chat_messages")
    op.drop_index(op.f("ix_chat_messages_sender_id"), table_name="chat_messages")
    op.drop_index(op.f("ix_chat_messages_family_id"), table_name="chat_messages")
    op.drop_table("chat_messages")
