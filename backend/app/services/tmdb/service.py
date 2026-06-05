"""TMDB module entry point — provider factory + thin wrappers, plus a small
in-process genre cache.

Plugins use this module, not the vendor client directly:

    from app.services.tmdb import search_movie, discover_movies, TmdbError

    try:
        match = await search_movie(title)
    except TmdbError:
        match = None  # degrade gracefully — metadata is optional

Caching: only the genre catalogue is cached (it's tiny and changes ~never), so a
片库 page open doesn't re-fetch it. Search / discover / details are NOT cached —
discover is paginated/filtered and a re-enrich should re-query for fresh data.
"""

from __future__ import annotations

import time

from app.core.config import Settings, settings
from app.services.tmdb.client import TmdbClient
from app.services.tmdb.types import TmdbGenre, TmdbMovie

# App-level sort keys → TMDB `sort_by`. The route validates against SORT_KEYS.
_SORT_BY = {
    "popular": "popularity.desc",
    "rating": "vote_average.desc",
    "newest": "primary_release_date.desc",
}
SORT_KEYS = tuple(_SORT_BY)
DEFAULT_SORT = "popular"

# Genre catalogue rarely changes; cache it process-locally for a day.
_GENRE_CACHE_TTL = 86_400.0
# (monotonic_expiry, genres)
_genre_cache: tuple[float, list[TmdbGenre]] | None = None


def get_tmdb_client(cfg: Settings | None = None) -> TmdbClient:
    """Build the TMDB client from settings. `cfg` is injectable for tests;
    defaults to the process settings singleton."""
    return TmdbClient.from_settings(cfg or settings)


def clear_tmdb_cache() -> None:
    """Drop the cached genre list — used by tests for isolation."""
    global _genre_cache
    _genre_cache = None


async def search_movie(
    query: str,
    *,
    client: TmdbClient | None = None,
) -> TmdbMovie | None:
    """Search TMDB for a movie by title, returning the best match or None.

    Raises `TmdbNotConfiguredError` when no credential is set and `TmdbError` on
    any provider/transport failure — callers should catch and degrade.
    """
    client = client or get_tmdb_client()
    return await client.search_movie(query)


async def get_movie(
    tmdb_id: int,
    *,
    client: TmdbClient | None = None,
) -> TmdbMovie | None:
    """Look up an exact TMDB movie by id (None when it no longer exists)."""
    client = client or get_tmdb_client()
    return await client.get_movie(tmdb_id)


async def fetch_poster_thumb(
    poster_path: str,
    *,
    client: TmdbClient | None = None,
) -> tuple[bytes, str] | None:
    """Download a 片库 browse thumbnail's bytes (for the backend image proxy),
    or None when unavailable. No credential needed — the image host is public."""
    client = client or get_tmdb_client()
    return await client.fetch_thumb(poster_path)


async def get_genres(*, client: TmdbClient | None = None) -> list[TmdbGenre]:
    """The movie-genre catalogue, served from a day-long process cache."""
    global _genre_cache
    now = time.monotonic()
    if _genre_cache is not None and _genre_cache[0] > now:
        return _genre_cache[1]
    client = client or get_tmdb_client()
    genres = await client.genres()
    _genre_cache = (now + _GENRE_CACHE_TTL, genres)
    return genres


async def discover_movies(
    *,
    genre_ids: list[int],
    sort: str = DEFAULT_SORT,
    page: int = 1,
    client: TmdbClient | None = None,
) -> list[TmdbMovie]:
    """Browse TMDB by genre + sort. `sort` is an app-level key (see SORT_KEYS);
    unknown keys fall back to the default."""
    client = client or get_tmdb_client()
    sort_by = _SORT_BY.get(sort, _SORT_BY[DEFAULT_SORT])
    return await client.discover_movies(genre_ids, sort_by, page)


__all__ = [
    "get_tmdb_client",
    "clear_tmdb_cache",
    "search_movie",
    "get_movie",
    "get_genres",
    "discover_movies",
    "fetch_poster_thumb",
    "SORT_KEYS",
    "DEFAULT_SORT",
]
