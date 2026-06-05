"""Movie plugin routes — list / create / update / delete.

URL space: `/families/{family_id}/plugins/movie/...` (mounted under `/api/v1`).
Every route enforces family membership.
"""

import contextlib
import re
from datetime import UTC, datetime
from urllib.parse import quote
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
from app.plugins.movie.enrich import enrich_movie
from app.plugins.movie.models import (
    MAX_INTRO_LEN,
    MAX_TITLE_LEN,
    DiscoverMovieRead,
    Movie,
    MovieCreate,
    MovieFromTmdb,
    MovieGenreRead,
    MovieRead,
    MovieUpdate,
)
from app.plugins.movie.service import build_read
from app.services.tmdb import (
    SORT_KEYS,
    TmdbError,
    TmdbNotConfiguredError,
    discover_movies,
    fetch_poster_thumb,
    get_genres,
    get_movie,
)

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
    intro / TMDB rating / poster from the title. The client shows a "补充中"
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


# ---- 片库 (TMDB discover) ---------------------------------------------------


def _tmdb_app_error(exc: TmdbError) -> AppError:
    """Map a TMDB failure to a clean client-facing error."""
    if isinstance(exc, TmdbNotConfiguredError):
        return AppError(ErrorCode.INTERNAL, "影库暂未配置(TMDB)", status_code=503)
    return AppError(ErrorCode.INTERNAL, "TMDB 暂时不可用,请稍后再试", status_code=502)


def _parse_genre_ids(raw: str | None) -> list[int]:
    """Parse a `?genres=18,36` query into ids, ignoring junk."""
    if not raw:
        return []
    return [int(p) for p in (s.strip() for s in raw.split(",")) if p.isdigit()]


# A TMDB poster path looks like `/wftnLZBxBBijNqDr2H6.jpg` — used to build the
# proxy URL and to validate the incoming `path` (anti-SSRF: no host, no
# traversal, image extensions only).
_POSTER_PATH_RE = re.compile(r"^/[\w-]+\.(?:jpg|jpeg|png|webp)$", re.IGNORECASE)


def _discover_poster_url(family_id: UUID, poster_path: str | None) -> str | None:
    """Host-relative URL of the backend thumbnail proxy for a TMDB poster path,
    so clients load 片库 thumbnails through us (not image.tmdb.org directly)."""
    if not poster_path:
        return None
    return (
        f"/api/v1/families/{family_id}/plugins/movie/discover/poster"
        f"?path={quote(poster_path, safe='')}"
    )


@router.get("/discover/genres", response_model=ApiResponse[list[MovieGenreRead]])
async def list_genres(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[MovieGenreRead]]:
    """The TMDB movie-genre catalogue (localized) for the 片库 filter chips."""
    await require_membership(session, current_user.id, family_id)
    try:
        genres = await get_genres()
    except TmdbError as exc:
        raise _tmdb_app_error(exc) from exc
    return ok([MovieGenreRead(id=g.id, name=g.name) for g in genres])


@router.get("/discover", response_model=ApiResponse[list[DiscoverMovieRead]])
async def discover(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    genres: str | None = None,
    sort: str = "popular",
    page: int = 1,
) -> ApiResponse[list[DiscoverMovieRead]]:
    """Browse TMDB by genre + sort. `genres` is a comma-separated id list (AND);
    `sort` is one of popular/rating/newest; `page` is 1-based (TMDB caps at 500).
    Each result flags whether it's already in this family's list."""
    await require_membership(session, current_user.id, family_id)
    sort_key = sort if sort in SORT_KEYS else "popular"
    page = max(1, min(page, 500))
    try:
        results = await discover_movies(
            genre_ids=_parse_genre_ids(genres), sort=sort_key, page=page
        )
    except TmdbError as exc:
        raise _tmdb_app_error(exc) from exc

    existing = set(
        (
            await session.execute(
                select(Movie.tmdb_id).where(
                    Movie.family_id == family_id,
                    Movie.tmdb_id.is_not(None),
                )
            )
        )
        .scalars()
        .all()
    )
    return ok(
        [
            DiscoverMovieRead(
                tmdb_id=m.id,
                title=m.title,
                overview=m.overview,
                release_date=m.release_date,
                tmdb_rating=m.vote_average,
                poster_url=_discover_poster_url(family_id, m.poster_path),
                already_added=m.id in existing,
            )
            for m in results
        ]
    )


@router.post(
    "/movies/from_tmdb", response_model=ApiResponse[MovieRead], status_code=201
)
async def add_from_tmdb(
    family_id: UUID,
    payload: MovieFromTmdb,
    session: SessionDep,
    current_user: CurrentUserDep,
    background: BackgroundTasks,
) -> ApiResponse[MovieRead]:
    """Add a 片库 result to the family's 想看 list by its TMDB id. Pre-fills the
    title / intro / rating from TMDB and schedules the background poster
    download, returning immediately with `ai_status="pending"`."""
    await require_membership(session, current_user.id, family_id)

    dup = (
        (
            await session.execute(
                select(Movie).where(
                    Movie.family_id == family_id,
                    Movie.tmdb_id == payload.tmdb_id,
                )
            )
        )
        .scalars()
        .first()
    )
    if dup is not None:
        raise AppError(
            ErrorCode.VALIDATION_ERROR, "这部已经在片单里了", status_code=400
        )

    try:
        match = await get_movie(payload.tmdb_id)
    except TmdbError as exc:
        raise _tmdb_app_error(exc) from exc
    if match is None:
        raise AppError(ErrorCode.NOT_FOUND, "未找到该电影", status_code=404)

    row = Movie(
        title=(match.title or "未命名")[:MAX_TITLE_LEN],
        family_id=family_id,
        created_by=current_user.id,
        tmdb_id=match.id,
        tmdb_media_type=match.media_type,
        intro=match.overview[:MAX_INTRO_LEN] if match.overview else None,
        tmdb_rating=match.vote_average,
        ai_status="pending",
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    # Background: re-fetch by id + download the poster, then mark ready.
    background.add_task(enrich_movie, row.id)
    return ok(build_read(row))


@router.get("/discover/poster")
async def get_discover_poster(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    path: str,
) -> Response:
    """Proxy a TMDB browse thumbnail through the backend so family clients don't
    need to reach image.tmdb.org directly. `path` is a TMDB poster path (e.g.
    `/abc.jpg`); only well-formed image paths are allowed (anti-SSRF). The bytes
    are immutable for a path, so they're cached hard."""
    await require_membership(session, current_user.id, family_id)
    if not _POSTER_PATH_RE.match(path):
        raise AppError(ErrorCode.VALIDATION_ERROR, "海报路径不合法", status_code=400)
    fetched = await fetch_poster_thumb(path)
    if fetched is None:
        raise AppError(ErrorCode.NOT_FOUND, "海报不存在", status_code=404)
    content, content_type = fetched
    return Response(
        content=content,
        media_type=content_type,
        headers={"Cache-Control": "public, max-age=2592000, immutable"},
    )
