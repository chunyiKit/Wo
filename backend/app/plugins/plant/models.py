"""Plant journal (植物日记) plugin tables.

Three resources:

- `Plant` (`plant_plants`): one plant a family is tending. Holds identity
  (name / species / emoji), a cover photo, placement (室内/阳台/窗向 — the main
  driver of real light), and user-set watering/fertilizing cycles plus their
  next-due dates (the reminder loop advances these).
- `PlantLog` (`plant_logs`): one dated care entry — a photo plus the AI's
  assessment and advice. The photo is persisted to blob storage (key + version)
  so the history timeline survives regardless of AI success; the env snapshot
  records the weather + placement at the time.
- `PlantFamilySettings` (`plant_family_settings`): the family's default
  environment (location), stored once; new plants inherit it.

We deliberately do NOT record who added a plant (no `created_by`) — per the
plugin's design, plant ownership is not surfaced.
"""

from datetime import UTC, date, datetime
from typing import Any, Literal
from uuid import UUID

from sqlalchemy import JSON, Column, Date, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

MAX_NAME_LEN = 40
MAX_SPECIES_LEN = 60
MAX_PLACEMENT_LEN = 24
MAX_NOTE_LEN = 500
MAX_ASSESSMENT_LEN = 2000
MAX_LABEL_LEN = 60
# Sane bounds for a care cycle in days (UI + validation guard).
MIN_INTERVAL_DAYS = 1
MAX_INTERVAL_DAYS = 365

# Family-shared placement label presets (input convenience; the label text is
# fed to the AI as environment context). A family can add/remove its own; when
# it hasn't customized them yet, these defaults are returned.
DEFAULT_PLACEMENTS: tuple[str, ...] = ("室内", "南阳台", "朝南窗", "朝北窗", "室外")
MAX_PLACEMENTS = 30

# AI analysis lifecycle for a care log:
# - pending: analysis scheduled / running in the background
# - ready:   analysis finished (assessment + advice present)
# - failed:  the AI call or parse failed; the client can offer a retry. The
#            photo and log row are kept regardless.
AiStatus = Literal["pending", "ready", "failed"]


# ---- Plant -----------------------------------------------------------------


class PlantBase(SQLModel):
    name: str = Field(max_length=MAX_NAME_LEN)
    emoji: str = Field(default="🌿", max_length=16)
    species: str | None = Field(default=None, max_length=MAX_SPECIES_LEN)
    # Placement decides real light (天气只给室外大环境). Free text within a small
    # cap; the client offers presets (室内 / 阳台 / 朝南窗 …).
    placement: str = Field(default="室内", max_length=MAX_PLACEMENT_LEN)
    # User-set care cycles (days). None = not set yet → no reminder armed. The
    # AI proposes suggested values on each log; the user adopts them explicitly.
    water_interval_days: int | None = Field(
        default=None, ge=MIN_INTERVAL_DAYS, le=MAX_INTERVAL_DAYS
    )
    fert_interval_days: int | None = Field(
        default=None, ge=MIN_INTERVAL_DAYS, le=MAX_INTERVAL_DAYS
    )


class Plant(PlantBase, table=True):
    __tablename__ = "plant_plants"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    # Cover photo lives in blob storage; we keep only the key + type, and a
    # version to bust client image caches when it's replaced.
    cover_storage_key: str | None = Field(default=None)
    cover_content_type: str | None = Field(default=None)
    cover_version: int = Field(default=0)
    # Next due dates the reminder loop advances by the matching interval.
    next_water_due: date | None = Field(
        default=None, sa_column=Column(Date, nullable=True)
    )
    next_fert_due: date | None = Field(
        default=None, sa_column=Column(Date, nullable=True)
    )
    # Dedup guards (internal): which due date we last reminded for.
    last_notified_water_due: date | None = Field(
        default=None, sa_column=Column(Date, nullable=True)
    )
    last_notified_fert_due: date | None = Field(
        default=None, sa_column=Column(Date, nullable=True)
    )


class PlantCreate(PlantBase):
    """POST request body."""


class PlantUpdate(SQLModel):
    """PUT request body — all fields optional for partial update.

    Setting `water_interval_days` / `fert_interval_days` (re)arms the matching
    reminder; the route recomputes `next_*_due` server-side.
    """

    name: str | None = Field(default=None, max_length=MAX_NAME_LEN)
    emoji: str | None = Field(default=None, max_length=16)
    species: str | None = Field(default=None, max_length=MAX_SPECIES_LEN)
    placement: str | None = Field(default=None, max_length=MAX_PLACEMENT_LEN)
    water_interval_days: int | None = Field(
        default=None, ge=MIN_INTERVAL_DAYS, le=MAX_INTERVAL_DAYS
    )
    fert_interval_days: int | None = Field(
        default=None, ge=MIN_INTERVAL_DAYS, le=MAX_INTERVAL_DAYS
    )


class PlantRead(PlantBase):
    id: UUID
    family_id: UUID
    created_at: datetime
    next_water_due: date | None = None
    next_fert_due: date | None = None
    # Host-relative cover URL with a `?v=` cache-buster (client prepends baseUrl
    # + image auth headers). None when no cover saved. Injected server-side.
    cover_url: str | None = None


# ---- PlantLog --------------------------------------------------------------


class PlantLog(SQLModel, table=True):
    __tablename__ = "plant_logs"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    plant_id: UUID = Field(
        foreign_key="plant_plants.id",
        ondelete="CASCADE",
        index=True,
    )
    # Denormalized for direct isolation queries / family-scoped scans.
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    # Photo persisted to blob storage — the durable history record. Saved in the
    # request, independent of AI success.
    photo_storage_key: str | None = Field(default=None)
    photo_content_type: str | None = Field(default=None)
    photo_version: int = Field(default=0)
    # Weather + placement captured at log time (for trend context / display).
    env_snapshot: dict[str, Any] | None = Field(
        default=None, sa_column=Column(JSON, nullable=True)
    )
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    # ---- AI analysis (filled by the background task) ----
    ai_status: str = Field(default="pending", max_length=16)
    ai_assessment: str | None = Field(default=None, max_length=MAX_ASSESSMENT_LEN)
    # Structured advice {watering, fertilizing, pruning, ...}.
    ai_advice: dict[str, Any] | None = Field(
        default=None, sa_column=Column(JSON, nullable=True)
    )
    # AI-suggested cycle values (days) — shown as suggestions; the user adopts
    # them to update the plant's intervals (never auto-applied).
    ai_suggested_water_days: int | None = Field(default=None)
    ai_suggested_fert_days: int | None = Field(default=None)


class PlantLogCreate(SQLModel):
    """POST body (photo is uploaded as multipart, not in this body)."""

    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)


class PlantLogRead(SQLModel):
    id: UUID
    plant_id: UUID
    family_id: UUID
    created_at: datetime
    note: str | None = None
    env_snapshot: dict[str, Any] | None = None
    ai_status: str = "pending"
    ai_assessment: str | None = None
    ai_advice: dict[str, Any] | None = None
    ai_suggested_water_days: int | None = None
    ai_suggested_fert_days: int | None = None
    # Host-relative photo URL with `?v=` cache-buster. Injected server-side.
    photo_url: str | None = None


# ---- Family default environment --------------------------------------------


class PlantFamilySettings(SQLModel, table=True):
    __tablename__ = "plant_family_settings"

    # One row per family — the family's default environment.
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        primary_key=True,
    )
    latitude: float | None = Field(default=None)
    longitude: float | None = Field(default=None)
    location_label: str | None = Field(default=None, max_length=MAX_LABEL_LEN)
    # Family-shared placement label presets. None = not customized yet (the
    # route returns DEFAULT_PLACEMENTS in that case).
    placements: list[str] | None = Field(
        default=None, sa_column=Column(JSON, nullable=True)
    )
    updated_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


class PlantFamilySettingsUpdate(SQLModel):
    """PUT body for the family default environment."""

    latitude: float | None = None
    longitude: float | None = None
    location_label: str | None = Field(default=None, max_length=MAX_LABEL_LEN)
    # Full replacement of the family's placement preset list (add/remove happen
    # client-side, then PUT the whole list).
    placements: list[str] | None = None


class PlantFamilySettingsRead(SQLModel):
    latitude: float | None = None
    longitude: float | None = None
    location_label: str | None = None
    # Always a non-empty list — defaults injected when the family hasn't set its own.
    placements: list[str] = []
