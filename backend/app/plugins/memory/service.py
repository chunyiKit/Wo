"""Memory business logic — media validation, read composition, preview hook.

Media validation auto-detects photo vs video from the bytes themselves rather
than trusting the client's declared type (same stance as the photo plugin):
images go through the shared Pillow check; videos are recognized by their ISO
base-media-file `ftyp` box (mp4 / mov) and accepted by an allow-list.
"""

import base64
from datetime import UTC, date, datetime
from uuid import UUID

from sqlalchemy import delete, func
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


# ---- Direct upload (COS 直传) --------------------------------------------


# Client-declared MIME → (kind, ext). Direct uploads bypass `validate_media`
# (the bytes never reach us), so the *declared* type is the only source for the
# storage key's extension — hence the strict allow-list. The declared value is
# still re-checked against the object's magic bytes at commit time.
_DECLARED_MEDIA: dict[str, tuple[str, str]] = {
    "image/jpeg": ("photo", "jpg"),
    "image/png": ("photo", "png"),
    "image/webp": ("photo", "webp"),
    "image/gif": ("photo", "gif"),
    "video/mp4": ("video", "mp4"),
    "video/quicktime": ("video", "mov"),
}


def resolve_declared_media(content_type: str) -> tuple[str, str, str]:
    """Map a client-declared MIME type to `(content_type, kind, ext)`.

    Raises `AppError(INVALID_IMAGE)` for anything off the allow-list: unlike the
    proxied upload path we can't fall back to sniffing the bytes, and an
    unknown type would otherwise land in the storage key verbatim.
    """
    declared = (content_type or "").split(";")[0].strip().lower()
    hit = _DECLARED_MEDIA.get(declared)
    if hit is None:
        raise AppError(
            ErrorCode.INVALID_IMAGE,
            f"不支持的文件类型：{declared or '未指定'}",
            status_code=400,
            details={"supported": sorted(_DECLARED_MEDIA)},
        )
    kind, ext = hit
    return declared, kind, ext


def sniff_kind(head: bytes) -> str | None:
    """Classify a blob from its leading bytes; None when inconclusive.

    The cheap stand-in for `validate_media` on the direct-upload path: we can't
    decode a 100 MB video we never received, but 16 bytes is enough to catch the
    case that actually matters — a payload whose real kind contradicts the
    declared one (which would otherwise render as a broken attachment).
    """
    if len(head) >= 12 and head[4:8] == b"ftyp":
        return "video"
    if head.startswith(b"\xff\xd8\xff"):  # JPEG
        return "photo"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "photo"
    if head.startswith(b"GIF8"):
        return "photo"
    if head.startswith(b"RIFF") and len(head) >= 12 and head[8:12] == b"WEBP":
        return "photo"
    return None


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


async def erase_user_data(session: AsyncSession, user_id: UUID) -> list[str]:
    """注销钩子：删除该用户在「回忆」里的全部数据，返回要删的存储对象 key。

    删三样东西，且顺序不能换：

    1. 他**创建**的回忆 —— 整条删除，连同下面的媒体与留言。注意：这些数据的
       可见范围可能是「全家可见」，其他成员此前一直看得见；用户既然选了
       「连内容一起删」，删掉就是预期行为（家庭相册会缺一段）。
    2. 他**上传**但挂在别人回忆里的媒体 —— 行删掉，别人的那条回忆少几张图。
    3. 他**写**在别人回忆下的留言。

    实现上刻意用 bulk delete 并**显式删子表**，不依赖外键的 ON DELETE CASCADE：
    生产是 Postgres（外键真实生效），但测试跑 SQLite，而 SQLite 的外键约束默认
    是关闭的 —— 靠级联会让两个环境行为不一致，测出来的绿灯是假的。
    """
    keys: list[str] = []

    # ① 他上传的媒体（无论挂在谁的回忆上）
    uploaded = await session.execute(
        select(MemoryMedia.storage_key).where(MemoryMedia.created_by == user_id)
    )
    keys.extend(uploaded.scalars().all())

    # ② 他创建的回忆
    own_ids = (
        await session.execute(select(Memory.id).where(Memory.created_by == user_id))
    ).scalars().all()

    if own_ids:
        # 这些回忆下的媒体 key 未必在 ① 里 —— 早年上传的行 created_by 可能是
        # 空。宁可多收几个 key（删不存在的对象是幂等的），也不能漏删。
        under_own = await session.execute(
            select(MemoryMedia.storage_key).where(MemoryMedia.memory_id.in_(own_ids))
        )
        keys.extend(under_own.scalars().all())

        await session.execute(
            delete(MemoryComment).where(MemoryComment.memory_id.in_(own_ids))
        )
        await session.execute(
            delete(MemoryMedia).where(MemoryMedia.memory_id.in_(own_ids))
        )
        await session.execute(delete(Memory).where(Memory.id.in_(own_ids)))

    # ③ 剩下的（挂在别人回忆上的）
    await session.execute(delete(MemoryMedia).where(MemoryMedia.created_by == user_id))
    await session.execute(delete(MemoryComment).where(MemoryComment.created_by == user_id))

    # 去重保序：① 与 ② 很可能收到同一个 key
    return list(dict.fromkeys(keys))
