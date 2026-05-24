"""Plugin platform tables — marketplace aggregates + per-family installations.

Static plugin metadata (name, description, default layout, etc.) lives in code
(see `app.plugins.registry`). This module stores only what changes at runtime:

- `Plugin`: aggregate metrics (install_count, rating) per plugin id.
- `InstalledPlugin`: one row per (family, installed plugin) with layout + config.

Layout (col/row/cw/ch) is stored as flat columns rather than JSONB so we can
validate uniqueness at the DB level later if needed, and so layout queries
stay index-friendly.
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import Column, DateTime
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7


class Plugin(SQLModel, table=True):
    """Marketplace aggregates. One row per registered plugin id."""

    __tablename__ = "plugins"

    id: str = Field(primary_key=True, max_length=32)  # matches PluginManifest.id
    rating: float = Field(default=0.0)
    install_count: int = Field(default=0, ge=0)
    current_version: str = Field(max_length=32)
    published_at: datetime = Field(
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class InstalledPlugin(SQLModel, table=True):
    """A plugin installed into a specific family, with its layout + config."""

    __tablename__ = "installed_plugins"
    # NOTE: no (family_id, plugin_id) unique constraint — multi-instance plugins
    # (e.g. anniversary) allow several cards of the same plugin per family, each
    # with its own `config`. Single-install is enforced in app.services.plugin
    # for plugins whose manifest has multi_instance=False.

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    plugin_id: str = Field(
        foreign_key="plugins.id",
        max_length=32,
        index=True,
    )
    enabled: bool = Field(default=True)

    # Grid coordinates — must satisfy 0 ≤ col, col+cw ≤ 4, 1 ≤ cw,ch ≤ 4.
    # App-level validators in `app.services.plugin` enforce this.
    col: int = Field(ge=0, le=3)
    row: int = Field(ge=0)
    cw: int = Field(ge=1, le=4)
    ch: int = Field(ge=1, le=4)

    config: dict = Field(
        default_factory=dict,
        sa_column=Column(JSONB, nullable=False, server_default="{}"),
    )

    installed_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    installed_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )
