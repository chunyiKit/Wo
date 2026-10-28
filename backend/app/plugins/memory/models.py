"""Memory plugin tables.

Three resources, all family-scoped:

- `Memory` (table `memory_memories`): one timeline entry — a moment a couple
  wants to keep. Carries a title, optional body, optional mood/location, and an
  `event_date` (the day it happened, which the timeline groups by).
- `MemoryMedia` (table `memory_media`): a photo or video attached to a memory.
  Never holds the bytes — only the storage key + metadata, mirroring the photo
  plugin. `sort_order` keeps the grid in the order the user arranged it.
- `MemoryComment` (table `memory_comments`): a short note one partner leaves on
  the other's memory — the two-way conversation that sets this apart from a
  plain diary.

`visibility` gates who in the family sees a memory: `family` (everyone, the
default), `couple` (treated like family in app code today — kept distinct so the
intent survives), and `private` (only the author). Filtering lives in the route
layer so the model stays a plain record.
"""

from datetime import UTC, date, datetime
from uuid import UUID

from sqlalchemy import Column, DateTime, Index
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

MAX_TITLE_LEN = 80
MAX_BODY_LEN = 2000
MAX_MOOD_LEN = 16
MAX_LOCATION_LEN = 80
MAX_COMMENT_LEN = 500

# Visibility values. `couple` currently behaves like `family` in filtering (a
# two-person family sees the same set), but we store it separately so the user's
# choice isn't silently rewritten.
VISIBILITY_VALUES = ("family", "couple", "private")
DEFAULT_VISIBILITY = "family"

MEDIA_KINDS = ("photo", "video")


# ---- Memory --------------------------------------------------------------


class MemoryBase(SQLModel):
    title: str = Field(max_length=MAX_TITLE_LEN)
    body: str | None = Field(default=None, max_length=MAX_BODY_LEN)
    mood: str | None = Field(default=None, max_length=MAX_MOOD_LEN)
    location: str | None = Field(default=None, max_length=MAX_LOCATION_LEN)
    visibility: str = Field(default=DEFAULT_VISIBILITY, max_length=16)


class Memory(MemoryBase, table=True):
    __tablename__ = "memory_memories"
    __table_args__ = (Index("ix_memory_timeline", "family_id", "event_date", "created_at", "id"),)

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    # The day the moment happened (timeline groups by this), distinct from the
    # row's created_at (when it was recorded).
    event_date: date = Field(index=True)
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    updated_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    created_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
        index=True,
    )


class MemoryCreate(MemoryBase):
    """POST request body. `event_date` defaults to today when omitted."""

    event_date: date | None = None
    # Stable across retries; reused as the resource UUID (no extra DB column).
    client_id: UUID | None = None


class MemoryUpdate(SQLModel):
    """PUT request body — all fields optional for partial update."""

    title: str | None = Field(default=None, max_length=MAX_TITLE_LEN)
    body: str | None = Field(default=None, max_length=MAX_BODY_LEN)
    mood: str | None = Field(default=None, max_length=MAX_MOOD_LEN)
    location: str | None = Field(default=None, max_length=MAX_LOCATION_LEN)
    visibility: str | None = Field(default=None, max_length=16)
    event_date: date | None = None


# ---- Media ---------------------------------------------------------------


class MemoryMedia(SQLModel, table=True):
    __tablename__ = "memory_media"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    memory_id: UUID = Field(
        foreign_key="memory_memories.id",
        ondelete="CASCADE",
        index=True,
    )
    # Denormalized family_id so storage keys and cleanup sweeps can be keyed by
    # family without a join back to the memory.
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    kind: str = Field(default="photo", max_length=8)  # photo | video

    storage_key: str = Field(max_length=255)
    content_type: str = Field(max_length=64)
    size_bytes: int = Field(ge=0)
    width: int | None = Field(default=None, ge=0)
    height: int | None = Field(default=None, ge=0)
    # Video clip length in milliseconds; null for photos. Supplied by the client
    # since the server doesn't transcode.
    duration_ms: int | None = Field(default=None, ge=0)

    sort_order: int = Field(default=0)
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


class MemoryMediaRead(SQLModel):
    id: UUID
    memory_id: UUID
    kind: str
    content_type: str
    size_bytes: int
    width: int | None
    height: int | None
    duration_ms: int | None
    sort_order: int
    # Relative URL of the raw-bytes endpoint. Client prepends host + auth header.
    url: str


# ---- Direct media URLs (微信小程序) ---------------------------------------


class MediaUrlsRequest(SQLModel):
    """Batch request for headerless media URLs (see `MediaUrlsResponse`)."""

    media_ids: list[UUID] = Field(min_length=1, max_length=200)


class MediaUrlsResponse(SQLModel):
    """Headerless (presigned) URLs for the requested media.

    Keys are media ids as strings (JSON object keys are always strings).
    Ids the caller may not see — or that don't exist — are simply absent, so the
    client treats "no entry" as "no image" without needing an error list.
    """

    urls: dict[str, str] = {}
    # All URLs in one batch expire together (signed at the same instant), so a
    # single timestamp is enough for the client to cache and re-fetch.
    expires_at: datetime


# ---- Direct upload (COS 直传) ---------------------------------------------


class MediaPresignRequest(SQLModel):
    """Ask for a ticket to upload one attachment straight to object storage."""

    # Declared MIME type. Pinned into the signed policy, so the client can't
    # upload something else under the same ticket.
    content_type: str = Field(max_length=64)
    client_id: UUID | None = None


class MediaPresignResponse(SQLModel):
    """A presigned POST ticket: post `fields` + the file to `url`.

    `fields` must precede the file part (COS stops reading at `file`). The
    ticket writes only a user-scoped staging object. Commit copies it to an
    independent final key and is idempotent by `media_id`.
    """

    media_id: UUID
    key: str
    url: str
    fields: dict[str, str] = {}
    file_field: str = "file"
    max_bytes: int
    expires_at: datetime


class MediaCommitRequest(SQLModel):
    """Record an object a client uploaded directly to object storage.

    `key` is echoed back so the server can prove it matches the key it handed
    out for this `media_id` — a client can't commit someone else's object.
    """

    media_id: UUID
    key: str = Field(max_length=255)
    content_type: str = Field(max_length=64)
    duration_ms: int | None = Field(default=None, ge=0)
    # Measured client-side (`wx.getImageInfo`); display-only, so trusting them
    # costs nothing. Ignored for video.
    width: int | None = Field(default=None, ge=0)
    height: int | None = Field(default=None, ge=0)


# ---- Comment -------------------------------------------------------------


class MemoryComment(SQLModel, table=True):
    __tablename__ = "memory_comments"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    memory_id: UUID = Field(
        foreign_key="memory_memories.id",
        ondelete="CASCADE",
        index=True,
    )
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    body: str = Field(max_length=MAX_COMMENT_LEN)
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


class MemoryCommentCreate(SQLModel):
    body: str = Field(max_length=MAX_COMMENT_LEN)


class MemoryCommentRead(SQLModel):
    id: UUID
    body: str
    created_at: datetime
    author_id: UUID | None = None
    author_name: str | None = None
    author_emoji: str | None = None
    # Member-avatar URL when the author uploaded a real photo; None → use emoji.
    author_avatar_url: str | None = None


# ---- Memory read (composed) ----------------------------------------------


class MemoryRead(MemoryBase):
    id: UUID
    family_id: UUID
    event_date: date
    created_at: datetime
    updated_at: datetime
    created_by: UUID | None
    # Author display info, injected server-side from the family's memberships.
    author_name: str | None = None
    author_emoji: str | None = None
    # Member-avatar URL when the author uploaded a real photo; None → use emoji.
    author_avatar_url: str | None = None
    media: list[MemoryMediaRead] = []
    comment_count: int = 0
    # Populated only on the detail endpoint; the list endpoint leaves it empty.
    comments: list[MemoryCommentRead] = []
