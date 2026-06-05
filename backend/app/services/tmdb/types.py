"""Provider-agnostic types for the shared TMDB module.

`TmdbMovie` is the slice of a TMDB search result the app cares about (enough to
fill a movie's intro / rating / poster). `TmdbProvider` is the structural type a
concrete client satisfies. Consumers (the movie plugin) depend only on these,
never on TMDB's raw JSON shape.

This module is a pure data supplier: given a title it returns movie metadata. It
holds NO business logic (no enrichment lifecycle, storage, UI) — that lives in
the consuming plugin.
"""

from __future__ import annotations

from collections.abc import Awaitable
from dataclasses import dataclass
from typing import Protocol


class TmdbError(Exception):
    """A call to TMDB failed (network, bad status, malformed body)."""


class TmdbNotConfiguredError(TmdbError):
    """No TMDB credential is set. Callers should treat this as feature-disabled
    rather than a transient failure (no point retrying)."""


@dataclass(frozen=True)
class TmdbMovie:
    """The fields the app uses from a TMDB movie result.

    `poster_path` is TMDB's path fragment (e.g. "/abc.jpg"), not a full URL —
    build the image URL via `TmdbProvider.poster_url`. `vote_average` is TMDB's
    0–10 community score. All optional except `id`/`title`, since TMDB omits
    fields for sparse entries.
    """

    id: int
    title: str
    original_title: str | None = None
    overview: str | None = None
    poster_path: str | None = None
    release_date: str | None = None
    vote_average: float | None = None
    vote_count: int | None = None


@dataclass(frozen=True)
class TmdbGenre:
    """A TMDB movie genre (stable numeric id + localized name), used to build the
    片库 (discover) filter and to pass `with_genres` back to TMDB."""

    id: int
    name: str


class TmdbProvider(Protocol):
    """Anything that can turn a title/filter into movie metadata and build poster
    URLs.

    `configured` lets callers (and tests) check credentials without a call.
    Lookups raise `TmdbNotConfiguredError` when unconfigured and `TmdbError` on
    any provider/transport failure; `search_movie`/`get_movie` return None when
    TMDB has no match.
    """

    @property
    def configured(self) -> bool: ...

    def search_movie(self, query: str) -> Awaitable[TmdbMovie | None]: ...

    def get_movie(self, tmdb_id: int) -> Awaitable[TmdbMovie | None]: ...

    def genres(self) -> Awaitable[list[TmdbGenre]]: ...

    def discover_movies(
        self, genre_ids: list[int], sort_by: str, page: int
    ) -> Awaitable[list[TmdbMovie]]: ...

    def poster_url(self, poster_path: str | None) -> str | None: ...


__all__ = [
    "TmdbError",
    "TmdbNotConfiguredError",
    "TmdbMovie",
    "TmdbGenre",
    "TmdbProvider",
]
