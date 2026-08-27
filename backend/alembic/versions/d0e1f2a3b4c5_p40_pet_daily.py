"""p40 independent family pets and pet daily plugin

Revision ID: d0e1f2a3b4c5
Revises: c9d0e1f2a3b4
Create Date: 2026-08-14 12:00:00.000000
"""

import logging
from collections.abc import Sequence
from datetime import UTC, datetime
from uuid import uuid4

import sqlalchemy as sa
import sqlmodel

from alembic import op

revision: str = "d0e1f2a3b4c5"
down_revision: str | None = "c9d0e1f2a3b4"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None
logger = logging.getLogger("alembic.runtime.migration")


def upgrade() -> None:
    op.create_table(
        "pets",
        sa.Column("name", sqlmodel.sql.sqltypes.AutoString(length=24), nullable=False),
        sa.Column("emoji", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("species", sqlmodel.sql.sqltypes.AutoString(length=32), nullable=True),
        sa.Column("breed", sqlmodel.sql.sqltypes.AutoString(length=64), nullable=True),
        sa.Column("sex", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=True),
        sa.Column("birthday", sa.Date(), nullable=True),
        sa.Column("birthday_estimated", sa.Boolean(), nullable=False),
        sa.Column("arrival_date", sa.Date(), nullable=True),
        sa.Column("neutered", sa.Boolean(), nullable=True),
        sa.Column("notes", sqlmodel.sql.sqltypes.AutoString(length=1000), nullable=True),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("photo_storage_key", sqlmodel.sql.sqltypes.AutoString(length=255), nullable=True),
        sa.Column("photo_content_type", sqlmodel.sql.sqltypes.AutoString(length=64), nullable=True),
        sa.Column("photo_version", sa.Integer(), nullable=False),
        sa.Column("created_by", sa.Uuid(), nullable=True),
        sa.Column("legacy_user_id", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["created_by"], ["users.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["legacy_user_id"], ["users.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_pets_family_id"), "pets", ["family_id"])
    op.create_index("ix_pets_family_active", "pets", ["family_id", "archived_at"])

    op.create_table(
        "pet_record_types",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("name", sqlmodel.sql.sqltypes.AutoString(length=32), nullable=False),
        sa.Column("emoji", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("data_kind", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("family_id", "name", name="uq_pet_record_types_family_name"),
    )
    op.create_index(op.f("ix_pet_record_types_family_id"), "pet_record_types", ["family_id"])

    op.create_table(
        "pet_care_plans",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("pet_id", sa.Uuid(), nullable=False),
        sa.Column("record_type_id", sa.Uuid(), nullable=False),
        sa.Column("name", sqlmodel.sql.sqltypes.AutoString(length=80), nullable=False),
        sa.Column("note", sqlmodel.sql.sqltypes.AutoString(length=2000), nullable=True),
        sa.Column("recurrence_unit", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False),
        sa.Column("recurrence_interval", sa.Integer(), nullable=False),
        sa.Column("next_due_date", sa.Date(), nullable=True),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.Column("last_notified_due_date", sa.Date(), nullable=True),
        sa.Column("created_by", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["created_by"], ["users.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["pet_id"], ["pets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["record_type_id"], ["pet_record_types.id"], ondelete="RESTRICT"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_pet_care_plans_family_id"), "pet_care_plans", ["family_id"])
    op.create_index(op.f("ix_pet_care_plans_pet_id"), "pet_care_plans", ["pet_id"])
    op.create_index(op.f("ix_pet_care_plans_record_type_id"), "pet_care_plans", ["record_type_id"])
    op.create_index(op.f("ix_pet_care_plans_next_due_date"), "pet_care_plans", ["next_due_date"])
    op.create_index(op.f("ix_pet_care_plans_active"), "pet_care_plans", ["active"])
    op.create_index(
        "ix_pet_care_plans_due_active",
        "pet_care_plans",
        ["active", "next_due_date", "family_id"],
    )

    op.create_table(
        "pet_records",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("pet_id", sa.Uuid(), nullable=False),
        sa.Column("record_type_id", sa.Uuid(), nullable=True),
        sa.Column(
            "type_name_snapshot", sqlmodel.sql.sqltypes.AutoString(length=32), nullable=False
        ),
        sa.Column(
            "type_emoji_snapshot", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False
        ),
        sa.Column(
            "data_kind_snapshot", sqlmodel.sql.sqltypes.AutoString(length=16), nullable=False
        ),
        sa.Column("name", sqlmodel.sql.sqltypes.AutoString(length=80), nullable=False),
        sa.Column("note", sqlmodel.sql.sqltypes.AutoString(length=2000), nullable=True),
        sa.Column("occurred_on", sa.Date(), nullable=False),
        sa.Column("next_due_date", sa.Date(), nullable=True),
        sa.Column("weight_kg", sa.Numeric(7, 3), nullable=True),
        sa.Column("plan_id", sa.Uuid(), nullable=True),
        sa.Column("scheduled_due_date", sa.Date(), nullable=True),
        sa.Column("created_by", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["created_by"], ["users.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["pet_id"], ["pets.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["plan_id"], ["pet_care_plans.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["record_type_id"], ["pet_record_types.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("plan_id", "scheduled_due_date", name="uq_pet_records_plan_due"),
    )
    op.create_index(op.f("ix_pet_records_family_id"), "pet_records", ["family_id"])
    op.create_index(op.f("ix_pet_records_pet_id"), "pet_records", ["pet_id"])
    op.create_index(op.f("ix_pet_records_record_type_id"), "pet_records", ["record_type_id"])
    op.create_index(op.f("ix_pet_records_occurred_on"), "pet_records", ["occurred_on"])
    op.create_index(op.f("ix_pet_records_plan_id"), "pet_records", ["plan_id"])
    op.create_index(
        "ix_pet_records_timeline",
        "pet_records",
        ["family_id", "pet_id", "occurred_on", "created_at", "id"],
    )
    op.create_index(
        "ix_pet_records_weight",
        "pet_records",
        ["family_id", "pet_id", "data_kind_snapshot", "occurred_on"],
    )

    op.create_table(
        "pet_record_attachments",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("record_id", sa.Uuid(), nullable=False),
        sa.Column(
            "original_filename", sqlmodel.sql.sqltypes.AutoString(length=255), nullable=False
        ),
        sa.Column("storage_key", sqlmodel.sql.sqltypes.AutoString(length=255), nullable=False),
        sa.Column("content_type", sqlmodel.sql.sqltypes.AutoString(length=64), nullable=False),
        sa.Column("size_bytes", sa.Integer(), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.Column("created_by", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["created_by"], ["users.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["family_id"], ["families.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["record_id"], ["pet_records.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_pet_record_attachments_family_id"), "pet_record_attachments", ["family_id"]
    )
    op.create_index(
        op.f("ix_pet_record_attachments_record_id"), "pet_record_attachments", ["record_id"]
    )

    _migrate_legacy_pet_memberships()


def _migrate_legacy_pet_memberships() -> None:
    bind = op.get_bind()
    legacy_rows = (
        bind.execute(
            sa.text(
                """
            SELECT m.user_id, m.family_id, m.display_name, m.avatar_emoji,
                   m.joined_at, u.avatar_storage_key, u.avatar_content_type,
                   u.avatar_version, u.current_family_id
              FROM memberships m
              JOIN users u ON u.id = m.user_id
             WHERE m.role = 'pet'
            """
            )
        )
        .mappings()
        .all()
    )
    logger.info("pet migration audit: %d legacy role=pet membership(s)", len(legacy_rows))
    migrated_with_photo = 0
    for row in legacy_rows:
        pet_id = uuid4()
        bind.execute(
            sa.text(
                """
                INSERT INTO pets (
                    id, family_id, name, emoji, birthday_estimated,
                    photo_storage_key, photo_content_type, photo_version,
                    created_by, legacy_user_id, created_at
                ) VALUES (
                    :id, :family_id, :name, :emoji, false,
                    :photo_storage_key, :photo_content_type, :photo_version,
                    :created_by, :legacy_user_id, :created_at
                )
                """
            ),
            {
                "id": pet_id,
                "family_id": row["family_id"],
                "name": row["display_name"],
                "emoji": row["avatar_emoji"],
                # Preserve a working photo pointer. A later upload moves it to
                # the dedicated pets/ key without risking migration failure.
                "photo_storage_key": row["avatar_storage_key"],
                "photo_content_type": row["avatar_content_type"],
                "photo_version": row["avatar_version"] or 0,
                "created_by": row["user_id"],
                "legacy_user_id": row["user_id"],
                "created_at": row["joined_at"] or datetime.now(UTC),
            },
        )
        if row["avatar_storage_key"]:
            migrated_with_photo += 1
        if row["current_family_id"] == row["family_id"]:
            next_family = bind.execute(
                sa.text(
                    """
                    SELECT family_id FROM memberships
                     WHERE user_id = :user_id
                       AND family_id <> :family_id
                       AND status = 'active'
                     ORDER BY joined_at
                     LIMIT 1
                    """
                ),
                {"user_id": row["user_id"], "family_id": row["family_id"]},
            ).scalar_one_or_none()
            bind.execute(
                sa.text("UPDATE users SET current_family_id = :next_family WHERE id = :user_id"),
                {"next_family": next_family, "user_id": row["user_id"]},
            )
        bind.execute(
            sa.text("DELETE FROM memberships WHERE user_id = :uid AND family_id = :fid"),
            {"uid": row["user_id"], "fid": row["family_id"]},
        )
    bind.execute(sa.text("DELETE FROM invitations WHERE role = 'pet' AND used_at IS NULL"))
    logger.info(
        "pet migration audit: migrated=%d, preserved_photo_pointer=%d; "
        "run python -m scripts.audit_pet_migration --copy-photos to normalize storage keys",
        len(legacy_rows),
        migrated_with_photo,
    )


def downgrade() -> None:
    bind = op.get_bind()
    rows = (
        bind.execute(
            sa.text(
                """
            SELECT legacy_user_id, family_id, name, emoji, created_at
              FROM pets
             WHERE legacy_user_id IS NOT NULL
            """
            )
        )
        .mappings()
        .all()
    )
    for row in rows:
        exists = bind.execute(
            sa.text("SELECT 1 FROM memberships WHERE user_id = :uid AND family_id = :fid"),
            {"uid": row["legacy_user_id"], "fid": row["family_id"]},
        ).scalar_one_or_none()
        if not exists:
            bind.execute(
                sa.text(
                    """
                    INSERT INTO memberships (
                        user_id, family_id, role, display_name, avatar_emoji,
                        status, joined_at
                    ) VALUES (
                        :uid, :fid, 'pet', :name, :emoji, 'active', :joined_at
                    )
                    """
                ),
                {
                    "uid": row["legacy_user_id"],
                    "fid": row["family_id"],
                    "name": row["name"],
                    "emoji": row["emoji"],
                    "joined_at": row["created_at"],
                },
            )

    op.drop_index(op.f("ix_pet_record_attachments_record_id"), table_name="pet_record_attachments")
    op.drop_index(op.f("ix_pet_record_attachments_family_id"), table_name="pet_record_attachments")
    op.drop_table("pet_record_attachments")
    op.drop_index("ix_pet_records_weight", table_name="pet_records")
    op.drop_index("ix_pet_records_timeline", table_name="pet_records")
    op.drop_index(op.f("ix_pet_records_plan_id"), table_name="pet_records")
    op.drop_index(op.f("ix_pet_records_occurred_on"), table_name="pet_records")
    op.drop_index(op.f("ix_pet_records_record_type_id"), table_name="pet_records")
    op.drop_index(op.f("ix_pet_records_pet_id"), table_name="pet_records")
    op.drop_index(op.f("ix_pet_records_family_id"), table_name="pet_records")
    op.drop_table("pet_records")
    op.drop_index("ix_pet_care_plans_due_active", table_name="pet_care_plans")
    op.drop_index(op.f("ix_pet_care_plans_active"), table_name="pet_care_plans")
    op.drop_index(op.f("ix_pet_care_plans_next_due_date"), table_name="pet_care_plans")
    op.drop_index(op.f("ix_pet_care_plans_record_type_id"), table_name="pet_care_plans")
    op.drop_index(op.f("ix_pet_care_plans_pet_id"), table_name="pet_care_plans")
    op.drop_index(op.f("ix_pet_care_plans_family_id"), table_name="pet_care_plans")
    op.drop_table("pet_care_plans")
    op.drop_index(op.f("ix_pet_record_types_family_id"), table_name="pet_record_types")
    op.drop_table("pet_record_types")
    op.drop_index("ix_pets_family_active", table_name="pets")
    op.drop_index(op.f("ix_pets_family_id"), table_name="pets")
    op.drop_table("pets")
