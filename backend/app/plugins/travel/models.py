"""Travel (旅行) plugin tables.

One row per trip record: a single original photo pinned to a city on the map,
plus an optional AI-restyled image (img2img via the family's image-gen model).
The AI image never replaces the original — `chosen` records which one the user
keeps as the card/thumbnail; both blobs are retained.
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import Column, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7


class TravelTrip(SQLModel, table=True):
    """A travel record: one city, one original photo, optional AI restyle."""

    __tablename__ = "travel_trips"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )

    # Where — city name + its lng/lat so the map can place the thumbnail.
    city_name: str = Field(max_length=40)
    city_lng: float
    city_lat: float
    # Optional specific place (e.g. 长江大桥 / 东方明珠), appended to the prompt.
    place: str | None = Field(default=None, max_length=60)

    caption: str | None = Field(default=None, max_length=200)

    # The trip's live image. Starts as the uploaded original; once the background
    # AI generation succeeds, this is replaced with the generated image and the
    # original blob is deleted (we don't keep the original). Column name kept for
    # migration simplicity — treat it as "the current image".
    original_key: str
    original_content_type: str = Field(max_length=40)
    original_width: int | None = Field(default=None)
    original_height: int | None = Field(default=None)

    # Async generation status: generating → ready (image replaced) | failed
    # (kept the original). Set on create; a background task updates it.
    ai_status: str = Field(default="generating", max_length=16)

    # DEPRECATED — left for table compatibility, no longer used by the new flow.
    ai_key: str | None = Field(default=None)
    ai_content_type: str | None = Field(default=None, max_length=40)
    ai_prompt: str | None = Field(default=None, max_length=400)
    ai_style: str | None = Field(default=None, max_length=20)
    chosen: str = Field(default="original", max_length=10)

    created_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    updated_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
