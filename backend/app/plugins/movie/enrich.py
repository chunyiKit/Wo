"""Movie enrichment — fills a movie's intro / rating / poster from its title via
The Movie Database (TMDB).

`enrich_movie` is the background task scheduled after a movie is created (and by
the manual re-enrich route). It opens its own DB session (the request's is gone
by the time it runs), searches TMDB for the title, best-effort downloads the
matched poster into our blob storage, and updates the row's enriched fields +
`ai_status`.

Design notes:
- Metadata comes from TMDB, matched by title (best/first result). The poster is
  downloaded server-side and re-stored in our own storage, so family clients
  fetch it from us and never call TMDB directly. A poster failure does NOT fail
  the whole enrichment (intro/rating still save).
- A missing credential, a TMDB transport error, or no match → `ai_status="failed"`
  (the client offers a retry; for a no-match the user can fix the title first).
- All exceptions are swallowed into `ai_status="failed"` so a flaky network never
  crashes the background task.
"""

from __future__ import annotations

import logging
from uuid import UUID

from app.core.database import async_session_maker
from app.core.storage import storage
from app.plugins.movie.models import MAX_INTRO_LEN, Movie
from app.services.tmdb import (
    TmdbError,
    TmdbMovie,
    get_by_id,
    get_tmdb_client,
    search_title,
)
from app.services.tmdb.images import download_tmdb_image

logger = logging.getLogger(__name__)

_POSTER_TIMEOUT = 20.0


async def _download_poster(url: str) -> tuple[bytes, str] | None:
    """Fetch the (full-size) poster bytes, or None if it isn't a usable image.
    A thin seam over the shared TMDB image downloader that tests can patch."""
    return await download_tmdb_image(url, timeout_seconds=_POSTER_TIMEOUT)


async def _save_poster(movie: Movie, url: str) -> None:
    """Best-effort: download `url` and store it as the movie's poster, bumping
    `poster_version` so clients re-fetch. A failure leaves the poster untouched."""
    downloaded = await _download_poster(url)
    if downloaded is None:
        return
    content, content_type = downloaded
    key = f"movie-posters/{movie.family_id}/{movie.id}.jpg"
    await storage.put(key, content, content_type)
    movie.poster_storage_key = key
    movie.poster_content_type = content_type
    movie.poster_version += 1


def _apply_match(movie: Movie, match: TmdbMovie) -> None:
    """Copy TMDB text fields onto the row (poster is handled separately)."""
    if match.overview:
        movie.intro = match.overview[:MAX_INTRO_LEN]
    movie.tmdb_rating = match.vote_average
    movie.tmdb_id = match.id
    movie.tmdb_media_type = match.media_type


async def enrich_movie(movie_id: UUID) -> None:
    """Background task: enrich one movie from its title via TMDB. Never raises."""
    async with async_session_maker() as session:
        movie = await session.get(Movie, movie_id)
        if movie is None:
            return
        title = movie.title.strip()

        try:
            # Entries with an exact TMDB id (added from 片库, or a prior enrich)
            # look up by id via the right endpoint for their kind. Title-typed
            # entries search TMDB's combined movie+TV index so shows/anime match
            # too, not just films.
            if movie.tmdb_id is not None:
                match = await get_by_id(
                    movie.tmdb_id, movie.tmdb_media_type or "movie"
                )
            else:
                match = await search_title(title)
        except TmdbError as exc:
            # Covers TmdbNotConfiguredError too: retrying won't help without a
            # key, but "failed" is the honest signal and keeps the UI consistent.
            logger.warning("movie enrich failed for %s: %s", movie_id, exc)
            movie.ai_status = "failed"
            session.add(movie)
            await session.commit()
            return

        if match is None:
            logger.info("movie enrich: no TMDB match for %r (%s)", title, movie_id)
            movie.ai_status = "failed"
            session.add(movie)
            await session.commit()
            return

        _apply_match(movie, match)

        poster_url = get_tmdb_client().poster_url(match.poster_path)
        if poster_url:
            await _save_poster(movie, poster_url)

        movie.ai_status = "ready"
        session.add(movie)
        await session.commit()


__all__ = ["enrich_movie"]
