"""Photo plugin routes — albums + photos + raw binary endpoint.

URL space: `/families/{family_id}/plugins/photo/...` (the prefix is mounted
under `/api/v1` by the v1 router).

Photo upload uses multipart/form-data: a single `file` part plus optional
`album_id` and `caption` form fields. The raw-bytes endpoint streams via a
plain Response (not enveloped) since the body is binary, not JSON.
"""

import contextlib
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, File, Form, UploadFile
from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select
from starlette.responses import Response

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.ids import new_uuid7
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.core.storage import storage
from app.plugins.photo.models import (
    Album,
    AlbumCreate,
    AlbumRead,
    Photo,
    PhotoRead,
)
from app.plugins.photo.service import (
    build_storage_key,
    to_photo_read,
    validate_image,
)

router = APIRouter(
    prefix="/families/{family_id}/plugins/photo",
    tags=["photo"],
)


# ---- Albums --------------------------------------------------------------


async def _album_with_count(session: AsyncSession, family_id: UUID, album: Album) -> AlbumRead:
    count_stmt = (
        select(func.count())
        .select_from(Photo)
        .where(Photo.family_id == family_id, Photo.album_id == album.id)
    )
    count = int((await session.execute(count_stmt)).scalar_one())
    return AlbumRead(
        id=album.id,
        family_id=album.family_id,
        name=album.name,
        description=album.description,
        cover_photo_id=album.cover_photo_id,
        photo_count=count,
        created_at=album.created_at,
        created_by=album.created_by,
    )


@router.get("/albums", response_model=ApiResponse[list[AlbumRead]])
async def list_albums(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[AlbumRead]]:
    await require_membership(session, current_user.id, family_id)
    stmt = select(Album).where(Album.family_id == family_id).order_by(Album.created_at.desc())
    albums = (await session.execute(stmt)).scalars().all()
    return ok([await _album_with_count(session, family_id, a) for a in albums])


@router.post(
    "/albums",
    response_model=ApiResponse[AlbumRead],
    status_code=201,
)
async def create_album(
    family_id: UUID,
    payload: AlbumCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[AlbumRead]:
    await require_membership(session, current_user.id, family_id)
    album = Album(
        **payload.model_dump(),
        family_id=family_id,
        created_by=current_user.id,
    )
    session.add(album)
    await session.commit()
    await session.refresh(album)
    return ok(await _album_with_count(session, family_id, album))


@router.delete("/albums/{album_id}", response_model=ApiResponse[dict])
async def delete_album(
    family_id: UUID,
    album_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    album = await session.get(Album, album_id)
    if album is None or album.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "相册不存在", status_code=404)
    await session.delete(album)
    await session.commit()
    # Photos previously in this album have album_id SET NULL via the FK and
    # remain accessible as "uncategorized". This matches the contract's intent
    # of not destroying user content on album deletion.
    return ok({"deleted": str(album_id)})


# ---- Photos --------------------------------------------------------------


@router.get("/photos", response_model=ApiResponse[list[PhotoRead]])
async def list_photos(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    album_id: UUID | None = None,
) -> ApiResponse[list[PhotoRead]]:
    """List photos, optionally scoped to one album.

    Returns newest first. Pagination is a TODO — we cap at 200 results to keep
    the response bounded until a cursor scheme lands.
    """
    await require_membership(session, current_user.id, family_id)
    stmt = (
        select(Photo)
        .where(Photo.family_id == family_id)
        .order_by(Photo.uploaded_at.desc())
        .limit(200)
    )
    if album_id is not None:
        stmt = stmt.where(Photo.album_id == album_id)
    photos = (await session.execute(stmt)).scalars().all()
    return ok([to_photo_read(p) for p in photos])


@router.post(
    "/photos",
    response_model=ApiResponse[PhotoRead],
    status_code=201,
)
async def upload_photo(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    file: Annotated[UploadFile, File(...)],
    album_id: Annotated[UUID | None, Form()] = None,
    caption: Annotated[str | None, Form()] = None,
) -> ApiResponse[PhotoRead]:
    await require_membership(session, current_user.id, family_id)

    # Verify the album (if any) belongs to this family — otherwise a member
    # could attach to someone else's album by guessing its id.
    if album_id is not None:
        album = await session.get(Album, album_id)
        if album is None or album.family_id != family_id:
            raise AppError(
                ErrorCode.NOT_FOUND,
                "相册不存在或不属于该家庭",
                status_code=404,
            )

    # Enforce size cap by reading one byte past the limit.
    cap = settings.max_upload_bytes
    content = await file.read(cap + 1)
    if len(content) > cap:
        raise AppError(
            ErrorCode.FILE_TOO_LARGE,
            f"文件超过上限 {cap // (1024 * 1024)} MB",
            status_code=413,
            details={"max_bytes": cap},
        )
    if not content:
        raise AppError(
            ErrorCode.INVALID_IMAGE,
            "上传内容为空",
            status_code=400,
        )

    content_type, ext, width, height = validate_image(content)

    # Reserve id + key first so we know the storage path before the row exists.
    photo_id = new_uuid7()
    storage_key = build_storage_key(family_id, photo_id, ext)

    # Write the blob first. If DB commit later fails we delete the file,
    # so we don't leak. If the file write fails we never insert the row.
    await storage.put(storage_key, content, content_type)

    try:
        photo = Photo(
            id=photo_id,
            family_id=family_id,
            album_id=album_id,
            storage_key=storage_key,
            content_type=content_type,
            size_bytes=len(content),
            width=width,
            height=height,
            caption=caption,
            uploaded_by=current_user.id,
        )
        session.add(photo)
        await session.commit()
        await session.refresh(photo)
    except Exception:
        # DB failed after the blob landed — clean up the orphan and bubble up.
        await storage.delete(storage_key)
        raise

    return ok(to_photo_read(photo))


@router.get("/photos/{photo_id}", response_model=ApiResponse[PhotoRead])
async def get_photo_metadata(
    family_id: UUID,
    photo_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PhotoRead]:
    await require_membership(session, current_user.id, family_id)
    photo = await session.get(Photo, photo_id)
    if photo is None or photo.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "照片不存在", status_code=404)
    return ok(to_photo_read(photo))


@router.get("/photos/{photo_id}/raw")
async def get_photo_raw(
    family_id: UUID,
    photo_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    """Serve the raw bytes. Membership-checked — returns 404 to non-members.

    Returns a plain Response (not the envelope) because the body is binary.
    """
    await require_membership(session, current_user.id, family_id)
    photo = await session.get(Photo, photo_id)
    if photo is None or photo.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "照片不存在", status_code=404)
    try:
        data = await storage.get(photo.storage_key)
    except FileNotFoundError as exc:
        # Metadata row exists but blob is gone (manual cleanup mid-flight?).
        raise AppError(
            ErrorCode.INTERNAL,
            "照片文件丢失",
            status_code=500,
        ) from exc
    return Response(content=data, media_type=photo.content_type)


@router.delete("/photos/{photo_id}", response_model=ApiResponse[dict])
async def delete_photo(
    family_id: UUID,
    photo_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    photo = await session.get(Photo, photo_id)
    if photo is None or photo.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "照片不存在", status_code=404)

    storage_key = photo.storage_key
    await session.delete(photo)
    await session.commit()

    # Best-effort file cleanup. Orphan blobs are recoverable later via a sweep
    # script keyed off (family_id, photo_id); a failure here shouldn't undo the
    # DB delete the user just observed succeed.
    with contextlib.suppress(Exception):
        await storage.delete(storage_key)

    return ok({"deleted": str(photo_id)})
