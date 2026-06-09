"""Memory business logic — media validation, read composition, preview hook.

Media validation auto-detects photo vs video from the bytes themselves rather
than trusting the client's declared type (same stance as the photo plugin):
images go through the shared Pillow check; videos are recognized by their ISO
base-media-file `ftyp` box (mp4 / mov) and accepted by an allow-list.
"""

import base64
from datetime import UTC, date, datetime
from uuid import UUID

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.errors import AppError, ErrorCode
from app.core.images import validate_image
from app.models.plugin import InstalledPlugin
from app.plugins.memory.models import (
    Memory,
    MemoryComment,
    MemoryCommentRead,
    MemoryMedia,
    MemoryMediaRead,
    MemoryRead,
)
from app.plugins.registry import PluginPreview
from app.services.membership import MemberInfo
from app.services.membership import author_avatar_url as _author_avatar_url
from app.services.membership import member_info_map as member_map

# Detected-format → (canonical content_type, file ext). Videos we accept but
# don't transcode; the client sends the clip already trimmed.
_VIDEO_FORMATS: dict[str, tuple[str, str]] = {
    "mp4": ("video/mp4", "mp4"),
    "mov": ("video/quicktime", "mov"),
}


def _sniff_video(data: bytes) -> tuple[str, str] | None:
    """Return (content_type, ext) if bytes look like an mp4/mov, else None.

    ISO base-media files put a `ftyp` box right after the 4-byte size, so bytes
    4..8 spell `ftyp`. The major brand (bytes 8..12) tells mp4 from mov.
    """
    if len(data) < 12 or data[4:8] != b"ftyp":
        return None
    brand = data[8:12]
    if brand.startswith(b"qt"):
        return _VIDEO_FORMATS["mov"]
    return _VIDEO_FORMATS["mp4"]


def validate_media(data: bytes) -> tuple[str, str, str, int | None, int | None]:
    """Classify uploaded bytes.

    Returns `(kind, content_type, ext, width, height)` where kind is
    "photo" or "video". Width/height are None for video. Raises
    `AppError(INVALID_IMAGE)` on anything that's neither a supported image nor a
    recognized video.
    """
    video = _sniff_video(data)
    if video is not None:
        content_type, ext = video
        return "video", content_type, ext, None, None

    # Not a video — fall back to the shared image validator, which raises a
    # clear error if the bytes aren't a supported image either.
    content_type, ext, width, height = validate_image(data)
    return "photo", content_type, ext, width, height


def build_storage_key(family_id: UUID, memory_id: UUID, media_id: UUID, ext: str) -> str:
    """Namespace media by family then memory for easy cleanup boundaries."""
    return f"memory/{family_id}/{memory_id}/{media_id}.{ext}"


def build_media_url(family_id: UUID, memory_id: UUID, media_id: UUID) -> str:
    """Relative URL of a media item's raw-bytes endpoint."""
    return f"/api/v1/families/{family_id}/plugins/memory/memories/{memory_id}/media/{media_id}/raw"


# ---- Read composition -----------------------------------------------------


def to_media_read(m: MemoryMedia) -> MemoryMediaRead:
    return MemoryMediaRead(
        id=m.id,
        memory_id=m.memory_id,
        kind=m.kind,
        content_type=m.content_type,
        size_bytes=m.size_bytes,
        width=m.width,
        height=m.height,
        duration_ms=m.duration_ms,
        sort_order=m.sort_order,
        url=build_media_url(m.family_id, m.memory_id, m.id),
    )


def to_comment_read(
    c: MemoryComment,
    members: dict[UUID, MemberInfo],
    family_id: UUID,
) -> MemoryCommentRead:
    info = members.get(c.created_by) if c.created_by is not None else None
    return MemoryCommentRead(
        id=c.id,
        body=c.body,
        created_at=c.created_at,
        author_id=c.created_by,
        author_name=info.name if info else None,
        author_emoji=info.emoji if info else None,
        author_avatar_url=_author_avatar_url(family_id, c.created_by, info),
    )


def build_read(
    memory: Memory,
    media: list[MemoryMedia],
    members: dict[UUID, MemberInfo],
    *,
    comment_count: int,
    comments: list[MemoryComment] | None = None,
) -> MemoryRead:
    """Serialize a memory with its media, author display info, and comments.

    `comments` is only passed on the detail path; the list path leaves it empty
    and just reports `comment_count`.
    """
    read = MemoryRead.model_validate(memory, from_attributes=True)
    info = members.get(memory.created_by) if memory.created_by is not None else None
    ordered = sorted(media, key=lambda m: (m.sort_order, m.created_at))
    return read.model_copy(
        update={
            "author_name": info.name if info else None,
            "author_emoji": info.emoji if info else None,
            "author_avatar_url": _author_avatar_url(memory.family_id, memory.created_by, info),
            "media": [to_media_read(m) for m in ordered],
            "comment_count": comment_count,
            "comments": [to_comment_read(c, members, memory.family_id) for c in (comments or [])],
        }
    )


# ---- Timeline cursor (keyset pagination) ----------------------------------


def encode_cursor(memory: Memory) -> str:
    """Opaque keyset cursor for the timeline: the page's last row's sort key
    `(event_date, created_at, id)`, base64url-encoded so the client carries it
    as a token it never has to parse."""
    raw = f"{memory.event_date.isoformat()}|{memory.created_at.isoformat()}|{memory.id}"
    return base64.urlsafe_b64encode(raw.encode()).decode()


def decode_cursor(token: str) -> tuple[date, datetime, UUID]:
    """Parse a cursor produced by `encode_cursor`. The cursor is client-supplied,
    so anything malformed is a 400 rather than a 500."""
    try:
        raw = base64.urlsafe_b64decode(token.encode()).decode()
        date_str, created_str, id_str = raw.split("|")
        return (
            date.fromisoformat(date_str),
            datetime.fromisoformat(created_str),
            UUID(id_str),
        )
    except (ValueError, TypeError) as exc:
        raise AppError(ErrorCode.VALIDATION_ERROR, "翻页游标不合法", status_code=400) from exc


# ---- Visibility -----------------------------------------------------------


def visible_to(memory: Memory, viewer_id: UUID | None) -> bool:
    """A `private` memory is only visible to its author; everything else is
    visible to any family member."""
    if memory.visibility != "private":
        return True
    return viewer_id is not None and memory.created_by == viewer_id


# ---- Preview --------------------------------------------------------------


async def preview_hook(
    session: AsyncSession, ip: InstalledPlugin, viewer_id: UUID | None = None
) -> PluginPreview:
    """Home card: the most recent memory's title + how many there are.

    Respects visibility — `private` memories only count toward (and surface to)
    their author. Newest is by `event_date`, then by recency of recording.
    """
    family_id = ip.family_id

    private_ok = Memory.visibility != "private"
    if viewer_id is not None:
        private_ok = private_ok | (Memory.created_by == viewer_id)

    count_stmt = (
        select(func.count()).select_from(Memory).where(Memory.family_id == family_id, private_ok)
    )
    total = int((await session.execute(count_stmt)).scalar_one())

    if total == 0:
        return PluginPreview(
            primary="还没有回忆",
            secondary="记下第一段时光",
            color_token="memory",
            emoji="📸",
        )

    latest_stmt = (
        select(Memory)
        .where(Memory.family_id == family_id, private_ok)
        .order_by(Memory.event_date.desc(), Memory.created_at.desc())
        .limit(1)
    )
    latest = (await session.execute(latest_stmt)).scalars().first()
    title = (latest.title if latest else "").strip() or "一段回忆"
    emoji = (latest.mood if latest and latest.mood else None) or "📸"

    # Latest 5 visible photos for the 4×2 card's right-side carousel.
    # Same private_ok filter as the title query — a non-author can't see a
    # private memory's photos sneaking in through the home card. Videos are
    # excluded (preview is a still-image carousel; rendering a video frame
    # would mean transcoding we don't want to do at preview time).
    photos_stmt = (
        select(MemoryMedia)
        .join(Memory, MemoryMedia.memory_id == Memory.id)
        .where(
            Memory.family_id == family_id,
            private_ok,
            MemoryMedia.kind == "photo",
        )
        .order_by(MemoryMedia.created_at.desc())
        .limit(5)
    )
    photos = list((await session.execute(photos_stmt)).scalars().all())
    image_urls = [build_media_url(family_id, p.memory_id, p.id) for p in photos]

    return PluginPreview(
        primary=title,
        secondary=f"共 {total} 条回忆",
        color_token="memory",
        emoji=emoji,
        image_urls=image_urls or None,
    )


__all__ = [
    "build_media_url",
    "build_read",
    "build_storage_key",
    "decode_cursor",
    "encode_cursor",
    "member_map",
    "preview_hook",
    "to_comment_read",
    "to_media_read",
    "validate_media",
    "visible_to",
]


# Re-exported for route convenience (avoids re-importing date/datetime there).
def today() -> date:
    return datetime.now(UTC).date()
