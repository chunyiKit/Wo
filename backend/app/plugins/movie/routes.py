"""Movie plugin routes — list / create / update / delete.

URL space: `/families/{family_id}/plugins/movie/...` (mounted under `/api/v1`).
Every route enforces family membership.
"""

import contextlib
from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks
from sqlmodel import select
from starlette.responses import RedirectResponse, Response

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.core.storage import PresignableStorage, storage
from app.plugins.movie.ai import enrich_movie
from app.plugins.movie.models import (
    Movie,
    MovieCreate,
    MovieRead,
    MovieUpdate,
)
from app.plugins.movie.service import build_read

router = APIRouter(
    prefix="/families/{family_id}/plugins/movie",
    tags=["movie"],
)


async def _load(session: SessionDep, family_id: UUID, movie_id: UUID) -> Movie:
    row = await session.get(Movie, movie_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "电影不存在", status_code=404)
    return row


@router.get("/movies", response_model=ApiResponse[list[MovieRead]])
async def list_movies(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    watched: bool | None = None,
) -> ApiResponse[list[MovieRead]]:
    """List the family's movies. `?watched=false` for the to-watch list,
    `?watched=true` for the history. Default returns both — to-watch newest
    first, then watched (most recent watch first)."""
    await require_membership(session, current_user.id, family_id)
    stmt = select(Movie).where(Movie.family_id == family_id)
    if watched is not None:
        stmt = stmt.where(Movie.watched.is_(watched))
    # Two-key order: watched at the bottom; within each group, newest first.
    # For 想看: by created_at DESC; for 看过: by watched_at DESC (when set,
    # fall back to created_at for the rare case of a forced flip without ts).
    stmt = stmt.order_by(
        Movie.watched,
        Movie.watched_at.desc().nullslast(),
        Movie.created_at.desc(),
    )
    rows = (await session.execute(stmt)).scalars().all()
    return ok([build_read(r) for r in rows])


@router.post("/movies", response_model=ApiResponse[MovieRead], status_code=201)
async def create_movie(
    family_id: UUID,
    payload: MovieCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
    background: BackgroundTasks,
) -> ApiResponse[MovieRead]:
    """Create a movie from a (possibly title-only) entry. Saving returns
    immediately with `ai_status="pending"`; a background task then fills in the
    intro / Douban rating / poster from the title. The client shows a "补充中"
    state and refreshes to pick up the enriched data."""
    await require_membership(session, current_user.id, family_id)
    title = payload.title.strip()
    if not title:
        raise AppError(ErrorCode.VALIDATION_ERROR, "片名不能为空", status_code=400)
    note = payload.note.strip() if payload.note else None
    row = Movie(
        title=title,
        note=note or None,
        family_id=family_id,
        created_by=current_user.id,
        ai_status="pending",
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    # Runs after the response is sent; opens its own DB session.
    background.add_task(enrich_movie, row.id)
    return ok(build_read(row))


@router.put("/movies/{movie_id}", response_model=ApiResponse[MovieRead])
async def update_movie(
    family_id: UUID,
    movie_id: UUID,
    payload: MovieUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[MovieRead]:
    """Partial update. Toggling `watched` here also stamps/clears `watched_at`
    so the client never has to think about it."""
    await require_membership(session, current_user.id, family_id)
    row = await _load(session, family_id, movie_id)
    updates = payload.model_dump(exclude_unset=True)
    if "title" in updates and updates["title"] is not None:
        title = updates["title"].strip()
        if not title:
            raise AppError(
                ErrorCode.VALIDATION_ERROR, "片名不能为空", status_code=400
            )
        updates["title"] = title
    if "note" in updates and updates["note"] is not None:
        note = updates["note"].strip()
        updates["note"] = note or None
    if "watched" in updates and updates["watched"] is not None:
        # Stamp / clear timestamp when status flips. Idempotent: re-marking
        # `watched=True` does NOT reset `watched_at` to "now" if it was already
        # set, so accidental double-toggles don't lose the original date.
        if updates["watched"] and row.watched_at is None:
            row.watched_at = datetime.now(UTC)
        elif not updates["watched"]:
            row.watched_at = None
    for key, value in updates.items():
        setattr(row, key, value)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(build_read(row))


@router.delete("/movies/{movie_id}", response_model=ApiResponse[dict])
async def delete_movie(
    family_id: UUID,
    movie_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    row = await _load(session, family_id, movie_id)
    # Drop the poster blob too, so a delete doesn't leak storage objects.
    # Best-effort: a storage hiccup must not block deleting the row.
    if row.poster_storage_key:
        with contextlib.suppress(Exception):
            await storage.delete(row.poster_storage_key)
    await session.delete(row)
    await session.commit()
    return ok({"deleted": str(movie_id)})


@router.post("/movies/{movie_id}/enrich", response_model=ApiResponse[MovieRead])
async def reenrich_movie(
    family_id: UUID,
    movie_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    background: BackgroundTasks,
) -> ApiResponse[MovieRead]:
    """Re-run AI enrichment for a movie (e.g. after a failure, or to refresh).
    Flips status back to `pending` and schedules the background task."""
    await require_membership(session, current_user.id, family_id)
    row = await _load(session, family_id, movie_id)
    row.ai_status = "pending"
    session.add(row)
    await session.commit()
    await session.refresh(row)
    background.add_task(enrich_movie, row.id)
    return ok(build_read(row))


@router.get("/movies/{movie_id}/poster")
async def get_movie_poster(
    family_id: UUID,
    movie_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    """Serve a movie's poster bytes. Membership-checked. With COS, 302-redirect
    to a 1-hour presigned URL so bytes come straight from object storage; local
    disk (dev/tests) streams inline. Mirrors the memory plugin's /raw pattern."""
    await require_membership(session, current_user.id, family_id)
    row = await _load(session, family_id, movie_id)
    if not row.poster_storage_key:
        raise AppError(ErrorCode.NOT_FOUND, "海报不存在", status_code=404)

    if isinstance(storage, PresignableStorage):
        url = await storage.presigned_get_url(row.poster_storage_key, ttl_seconds=3600)
        return RedirectResponse(url, status_code=302)

    try:
        data = await storage.get(row.poster_storage_key)
    except FileNotFoundError as exc:
        raise AppError(ErrorCode.INTERNAL, "海报文件丢失", status_code=500) from exc
    return Response(content=data, media_type=row.poster_content_type or "image/jpeg")
