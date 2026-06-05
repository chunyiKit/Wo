"""TMDB (The Movie Database) provider — REST client for movie metadata.

Mirrors `app.services.weather.qweather.QWeatherClient`: a frozen dataclass built
`from_settings`, a `configured` guard, and httpx calls wrapped so any transport
failure surfaces as the module's domain error (`TmdbError`).

Surface:
- `search_movie(title)`   — best-match lookup by title (the 想看 quick-add path).
- `get_movie(tmdb_id)`    — exact lookup by id (the 片库 add + re-enrich path).
- `genres()`              — the movie-genre catalogue (片库 filter chips).
- `discover_movies(...)`  — browse by genre + sort (the 片库 grid).

Auth: TMDB accepts either a v4 **Read Access Token** (sent as
`Authorization: Bearer <token>`, preferred) or a v3 **API key** (sent as an
`api_key` query param). Both are issued together at signup; this client uses the
bearer token when present and falls back to the api key.

Network note: `api.themoviedb.org` / `image.tmdb.org` are not always reachable
from mainland China. Both hosts are configurable (`tmdb_base_url`,
`tmdb_image_base_url`) so a deployment behind the GFW can point them at a reverse
proxy / mirror. Saved-movie posters are downloaded server-side and re-stored in
our own blob storage; only 片库 *browse* thumbnails are loaded from the image
host directly by clients.

The `parse_*` functions are pure (no network) so result-shaping is unit-testable.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

import httpx

from app.services.tmdb.images import download_tmdb_image
from app.services.tmdb.types import (
    TmdbError,
    TmdbGenre,
    TmdbMovie,
    TmdbNotConfiguredError,
)

if TYPE_CHECKING:
    from app.core.config import Settings

logger = logging.getLogger(__name__)


def _to_float(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _to_int(value: Any) -> int | None:
    f = _to_float(value)
    return int(f) if f is not None else None


def _clean(value: Any) -> str | None:
    """Trim a string field; treat empty/whitespace (TMDB's sentinel for a
    missing translation, e.g. an untranslated overview) as absent."""
    if isinstance(value, str):
        s = value.strip()
        return s or None
    return None


def _parse_movie(item: Any) -> TmdbMovie | None:
    """Shape one TMDB *movie* object (search result, discover result, or the
    /movie/{id} details payload — they share these fields) into a `TmdbMovie`.
    None when the object has no usable id."""
    if not isinstance(item, dict):
        return None
    mid = _to_int(item.get("id"))
    if mid is None:
        return None
    return TmdbMovie(
        id=mid,
        title=_clean(item.get("title")) or _clean(item.get("original_title")) or "",
        original_title=_clean(item.get("original_title")),
        overview=_clean(item.get("overview")),
        poster_path=_clean(item.get("poster_path")),
        release_date=_clean(item.get("release_date")),
        vote_average=_to_float(item.get("vote_average")),
        vote_count=_to_int(item.get("vote_count")),
        media_type="movie",
    )


def _parse_tv(item: Any) -> TmdbMovie | None:
    """Shape one TMDB *TV* object into a `TmdbMovie`, mapping TV-specific field
    names (`name`/`original_name`/`first_air_date`) onto the shared fields so
    callers treat movies and shows uniformly."""
    if not isinstance(item, dict):
        return None
    mid = _to_int(item.get("id"))
    if mid is None:
        return None
    return TmdbMovie(
        id=mid,
        title=_clean(item.get("name")) or _clean(item.get("original_name")) or "",
        original_title=_clean(item.get("original_name")),
        overview=_clean(item.get("overview")),
        poster_path=_clean(item.get("poster_path")),
        release_date=_clean(item.get("first_air_date")),
        vote_average=_to_float(item.get("vote_average")),
        vote_count=_to_int(item.get("vote_count")),
        media_type="tv",
    )


def _parse_multi_item(item: Any) -> TmdbMovie | None:
    """Dispatch one `/search/multi` result by its `media_type`. Returns None for
    persons (and anything unrecognized)."""
    if not isinstance(item, dict):
        return None
    media_type = item.get("media_type")
    if media_type == "movie":
        return _parse_movie(item)
    if media_type == "tv":
        return _parse_tv(item)
    return None


def parse_multi(body: dict[str, Any]) -> TmdbMovie | None:
    """Best movie/tv match from a `/search/multi` response — the first result
    that's a movie or show (persons are skipped). Pure."""
    results = body.get("results")
    if not isinstance(results, list):
        return None
    for item in results:
        parsed = _parse_multi_item(item)
        if parsed is not None:
            return parsed
    return None


def parse_search(body: dict[str, Any]) -> TmdbMovie | None:
    """Best-match from a `/search/movie` response. Pure. Picks result[0] — TMDB
    sorts by relevance, so the first hit is the best match for a title."""
    results = body.get("results")
    if not isinstance(results, list) or not results:
        return None
    return _parse_movie(results[0])


def parse_discover(body: dict[str, Any]) -> list[TmdbMovie]:
    """All usable results from a `/discover/movie` response, in TMDB order. Pure."""
    results = body.get("results")
    if not isinstance(results, list):
        return []
    return [m for m in (_parse_movie(item) for item in results) if m is not None]


def parse_genres(body: dict[str, Any]) -> list[TmdbGenre]:
    """The genre list from a `/genre/movie/list` response. Pure."""
    genres = body.get("genres")
    if not isinstance(genres, list):
        return []
    out: list[TmdbGenre] = []
    for g in genres:
        if not isinstance(g, dict):
            continue
        gid = _to_int(g.get("id"))
        name = _clean(g.get("name"))
        if gid is not None and name:
            out.append(TmdbGenre(id=gid, name=name))
    return out


@dataclass(frozen=True)
class TmdbClient:
    access_token: str
    api_key: str
    base_url: str
    image_base_url: str
    poster_size: str
    language: str
    timeout_seconds: float
    thumb_size: str = "w342"
    discover_min_votes: int = 200
    # Injectable for tests (httpx.MockTransport). None → real network transport.
    transport: httpx.AsyncBaseTransport | None = None

    @classmethod
    def from_settings(cls, settings: Settings) -> TmdbClient:
        return cls(
            access_token=settings.tmdb_access_token,
            api_key=settings.tmdb_api_key,
            base_url=settings.tmdb_base_url.rstrip("/"),
            image_base_url=settings.tmdb_image_base_url.rstrip("/"),
            poster_size=settings.tmdb_poster_size,
            language=settings.tmdb_language,
            timeout_seconds=settings.tmdb_timeout_seconds,
            thumb_size=settings.tmdb_thumb_size,
            discover_min_votes=settings.tmdb_discover_min_votes,
        )

    @property
    def configured(self) -> bool:
        return bool(self.access_token or self.api_key)

    def _ensure_configured(self) -> None:
        if not self.configured:
            raise TmdbNotConfiguredError("TMDB 未配置 access token / api key")

    def _headers(self) -> dict[str, str]:
        # v4 Read Access Token → Bearer header (preferred when set).
        if self.access_token:
            return {"Authorization": f"Bearer {self.access_token}"}
        return {}

    def _params(self, extra: dict[str, Any]) -> dict[str, Any]:
        params = dict(extra)
        # v3 api_key auth only when no bearer token is configured.
        if not self.access_token and self.api_key:
            params["api_key"] = self.api_key
        return params

    def poster_url(self, poster_path: str | None) -> str | None:
        """Build a full poster URL from a TMDB `poster_path` (which starts with
        "/"), or None when there's no poster."""
        if not poster_path:
            return None
        return f"{self.image_base_url}/{self.poster_size}{poster_path}"

    def thumb_url(self, poster_path: str | None) -> str | None:
        """Like `poster_url` but at the smaller browse-thumbnail size."""
        if not poster_path:
            return None
        return f"{self.image_base_url}/{self.thumb_size}{poster_path}"

    async def fetch_thumb(self, poster_path: str) -> tuple[bytes, str] | None:
        """Download a browse thumbnail's bytes (for the 片库 backend proxy), or
        None when unavailable. No credential needed — the image host is public."""
        url = self.thumb_url(poster_path)
        if url is None:
            return None
        return await download_tmdb_image(
            url, timeout_seconds=self.timeout_seconds, transport=self.transport
        )

    async def _request(
        self,
        path: str,
        params: dict[str, Any],
        *,
        none_on_404: bool = False,
    ) -> dict[str, Any] | None:
        """GET `path`, returning the decoded JSON body. Raises `TmdbError` on
        transport failure / non-200; returns None for 404 when `none_on_404`."""
        async with httpx.AsyncClient(
            timeout=self.timeout_seconds, transport=self.transport
        ) as http:
            try:
                resp = await http.get(
                    f"{self.base_url}{path}",
                    params=self._params(params),
                    headers=self._headers(),
                )
            except httpx.HTTPError as exc:
                raise TmdbError(f"TMDB 请求失败: {exc}") from exc
        if none_on_404 and resp.status_code == 404:
            return None
        if resp.status_code != 200:
            raise TmdbError(f"TMDB 返回错误: {resp.status_code}")
        try:
            return resp.json()
        except ValueError as exc:
            raise TmdbError("TMDB 返回非 JSON 内容") from exc

    async def search_movie(self, query: str) -> TmdbMovie | None:
        self._ensure_configured()
        title = query.strip()
        if not title:
            return None
        body = await self._request(
            "/search/movie",
            {
                "query": title,
                "language": self.language,
                "include_adult": "false",
                "page": "1",
            },
        )
        return parse_search(body or {})

    async def search_multi(self, query: str) -> TmdbMovie | None:
        """Search movies AND TV together (the 看电影 watch-list holds both), best
        movie/tv match or None. Persons are ignored."""
        self._ensure_configured()
        title = query.strip()
        if not title:
            return None
        body = await self._request(
            "/search/multi",
            {
                "query": title,
                "language": self.language,
                "include_adult": "false",
                "page": "1",
            },
        )
        return parse_multi(body or {})

    async def get_movie(self, tmdb_id: int) -> TmdbMovie | None:
        self._ensure_configured()
        body = await self._request(
            f"/movie/{tmdb_id}",
            {"language": self.language},
            none_on_404=True,
        )
        return None if body is None else _parse_movie(body)

    async def get_tv(self, tmdb_id: int) -> TmdbMovie | None:
        self._ensure_configured()
        body = await self._request(
            f"/tv/{tmdb_id}",
            {"language": self.language},
            none_on_404=True,
        )
        return None if body is None else _parse_tv(body)

    async def genres(self) -> list[TmdbGenre]:
        self._ensure_configured()
        body = await self._request("/genre/movie/list", {"language": self.language})
        return parse_genres(body or {})

    async def discover_movies(
        self,
        genre_ids: list[int],
        sort_by: str,
        page: int = 1,
    ) -> list[TmdbMovie]:
        self._ensure_configured()
        params: dict[str, Any] = {
            "language": self.language,
            "include_adult": "false",
            "sort_by": sort_by,
            "page": str(page),
        }
        if genre_ids:
            # Comma = AND (a title must carry every selected genre), matching
            # TMDB's own discover behaviour.
            params["with_genres"] = ",".join(str(g) for g in genre_ids)
        if sort_by.startswith("vote_average"):
            # Without a vote floor, score-sort surfaces obscure 10.0 titles.
            params["vote_count.gte"] = str(self.discover_min_votes)
        body = await self._request("/discover/movie", params)
        return parse_discover(body or {})


__all__ = [
    "TmdbClient",
    "parse_search",
    "parse_multi",
    "parse_discover",
    "parse_genres",
]
