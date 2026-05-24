"""Photo plugin tables.

Two resources:
- `Album` (table `photo_albums`): a named grouping inside a family.
- `Photo` (table `photo_photos`): an individual image, optionally in an album.

Note: `Album.cover_photo_id` is intentionally NOT a database FK to `photo_photos`.
A bidirectional FK between the two tables would require deferred constraints
to break the cycle at CREATE TABLE time. We enforce the reference in
application code (best-effort — cover may dangle if photo is deleted, which
the read path treats as "no cover").
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import Column, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7


class AlbumBase(SQLModel):
    name: str = Field(max_length=64)
    description: str | None = Field(default=None, max_length=200)


class Album(AlbumBase, table=True):
    __tablename__ = "photo_albums"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    # No DB FK to photos to avoid circular references — see module docstring.
    cover_photo_id: UUID | None = Field(default=None, nullable=True)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    created_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )


class AlbumCreate(AlbumBase):
    """POST request body."""


class AlbumRead(AlbumBase):
    id: UUID
    family_id: UUID
    cover_photo_id: UUID | None
    photo_count: int = 0
    created_at: datetime
    created_by: UUID | None


class PhotoBase(SQLModel):
    caption: str | None = Field(default=None, max_length=200)


class Photo(PhotoBase, table=True):
    __tablename__ = "photo_photos"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    album_id: UUID | None = Field(
        default=None,
        foreign_key="photo_albums.id",
        ondelete="SET NULL",
        nullable=True,
        index=True,
    )

    # Storage layer info — never holds the bytes themselves.
    storage_key: str = Field(max_length=255)
    content_type: str = Field(max_length=64)
    size_bytes: int = Field(ge=0)
    width: int | None = Field(default=None, ge=0)
    height: int | None = Field(default=None, ge=0)

    uploaded_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    uploaded_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )


class PhotoRead(PhotoBase):
    id: UUID
    family_id: UUID
    album_id: UUID | None
    content_type: str
    size_bytes: int
    width: int | None
    height: int | None
    uploaded_at: datetime
    uploaded_by: UUID | None
    # Relative URL pointing to the raw-bytes endpoint. Client prepends host.
    url: str
