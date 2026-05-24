"""p6_multi_instance_plugins

Drops the (family_id, plugin_id) unique constraint on installed_plugins so a
family can install a plugin more than once. Multi-instance plugins (e.g.
anniversary) use this to place several cards, each with its own `config`.
Single-install is still enforced in app.services.plugin for plugins whose
manifest has multi_instance=False.

Revision ID: c3d4e5f6a7b8
Revises: a1b2c3d4e5f6
Create Date: 2026-05-24 18:30:00.000000

"""
from collections.abc import Sequence

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "c3d4e5f6a7b8"
down_revision: str | None = "a1b2c3d4e5f6"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_constraint(
        "uq_installed_family_plugin", "installed_plugins", type_="unique"
    )


def downgrade() -> None:
    op.create_unique_constraint(
        "uq_installed_family_plugin",
        "installed_plugins",
        ["family_id", "plugin_id"],
    )
