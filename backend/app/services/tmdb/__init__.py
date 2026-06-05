"""Shared TMDB module — a provider-agnostic way for plugins to fetch movie
metadata (intro / rating / poster) and browse the catalogue, backed by The Movie
Database.

Public surface (import from here, not the submodules):

    from app.services.tmdb import (
        search_movie,     # title -> best-match TmdbMovie | None
        get_movie,        # tmdb_id -> exact TmdbMovie | None
        get_genres,       # the movie-genre catalogue (cached)
        discover_movies,  # browse by genre + sort
        get_tmdb_client,  # the configured client (for poster_url, etc.)
        SORT_KEYS,        # valid app-level sort keys for discover
        TmdbMovie, TmdbGenre,
        TmdbError, TmdbNotConfiguredError,
    )

This module supplies movie data only — it holds no business logic (no enrichment
lifecycle, storage, or UI concerns); that lives in the movie plugin.
"""

from app.services.tmdb.client import TmdbClient
from app.services.tmdb.service import (
    DEFAULT_SORT,
    SORT_KEYS,
    clear_tmdb_cache,
    discover_movies,
    fetch_poster_thumb,
    get_by_id,
    get_genres,
    get_movie,
    get_tmdb_client,
    search_movie,
    search_title,
)
from app.services.tmdb.types import (
    TmdbError,
    TmdbGenre,
    TmdbMovie,
    TmdbNotConfiguredError,
    TmdbProvider,
)

__all__ = [
    "search_movie",
    "search_title",
    "get_movie",
    "get_by_id",
    "get_genres",
    "discover_movies",
    "fetch_poster_thumb",
    "get_tmdb_client",
    "clear_tmdb_cache",
    "SORT_KEYS",
    "DEFAULT_SORT",
    "TmdbClient",
    "TmdbMovie",
    "TmdbGenre",
    "TmdbProvider",
    "TmdbError",
    "TmdbNotConfiguredError",
]
