"""TMDB module tests — pure parsing, poster-URL building, auth shaping, the
not-configured guard, and an end-to-end call against a mocked transport."""

import httpx
import pytest

from app.services.tmdb import TmdbNotConfiguredError
from app.services.tmdb.client import (
    TmdbClient,
    parse_discover,
    parse_genres,
    parse_search,
)

_SEARCH_BODY = {
    "results": [
        {
            "id": 27205,
            "title": "盗梦空间",
            "original_title": "Inception",
            "overview": "一名盗取潜意识机密的窃贼接下一桩植入意念的任务……",
            "poster_path": "/abc.jpg",
            "release_date": "2010-07-15",
            "vote_average": 8.369,
            "vote_count": 34000,
        },
        {"id": 1, "title": "其它结果"},
    ]
}


# ---- pure parser -----------------------------------------------------------


def test_parse_search_picks_first_result() -> None:
    movie = parse_search(_SEARCH_BODY)
    assert movie is not None
    assert movie.id == 27205
    assert movie.title == "盗梦空间"
    assert movie.original_title == "Inception"
    assert movie.overview.startswith("一名")
    assert movie.poster_path == "/abc.jpg"
    assert movie.vote_average == pytest.approx(8.369)
    assert movie.vote_count == 34000


def test_parse_search_empty_returns_none() -> None:
    assert parse_search({"results": []}) is None
    assert parse_search({}) is None


def test_parse_search_blank_overview_is_none() -> None:
    """TMDB returns an empty overview when it has no translation — treat as absent."""
    body = {"results": [{"id": 5, "title": "X", "overview": "   "}]}
    movie = parse_search(body)
    assert movie is not None
    assert movie.overview is None


# ---- client: poster url + auth shaping -------------------------------------


def _client(transport: httpx.AsyncBaseTransport | None, **over) -> TmdbClient:
    base = dict(
        access_token="tok",
        api_key="",
        base_url="https://api.themoviedb.org/3",
        image_base_url="https://image.tmdb.org/t/p",
        poster_size="w500",
        language="zh-CN",
        timeout_seconds=5.0,
        transport=transport,
    )
    base.update(over)
    return TmdbClient(**base)


def test_poster_url_builds_full_url() -> None:
    c = _client(None)
    assert c.poster_url("/abc.jpg") == "https://image.tmdb.org/t/p/w500/abc.jpg"
    assert c.poster_url(None) is None


async def test_search_movie_uses_bearer_auth() -> None:
    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["auth"] = request.headers.get("authorization")
        seen["query"] = dict(request.url.params)
        return httpx.Response(200, json=_SEARCH_BODY)

    c = _client(httpx.MockTransport(handler))
    movie = await c.search_movie("盗梦空间")
    assert movie is not None and movie.id == 27205
    assert seen["auth"] == "Bearer tok"
    assert "api_key" not in seen["query"]
    assert seen["query"]["language"] == "zh-CN"
    assert seen["query"]["query"] == "盗梦空间"


async def test_search_movie_api_key_fallback() -> None:
    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["auth"] = request.headers.get("authorization")
        seen["query"] = dict(request.url.params)
        return httpx.Response(200, json={"results": []})

    c = _client(httpx.MockTransport(handler), access_token="", api_key="k123")
    result = await c.search_movie("x")
    assert result is None  # empty results → no match
    assert seen["auth"] is None
    assert seen["query"]["api_key"] == "k123"


async def test_search_movie_not_configured_raises() -> None:
    c = _client(None, access_token="", api_key="")
    with pytest.raises(TmdbNotConfiguredError):
        await c.search_movie("x")


# ---- discover / genres / details -------------------------------------------

_DISCOVER_BODY = {
    "results": [
        {"id": 1, "title": "甲", "vote_average": 8.1, "poster_path": "/a.jpg"},
        {"id": 2, "title": "乙", "vote_average": 7.0},
        {"not": "a dict"},  # tolerated / skipped
    ]
}
_GENRES_BODY = {
    "genres": [{"id": 28, "name": "动作"}, {"id": 18, "name": "剧情"}, {"bad": 1}]
}


def test_parse_discover_keeps_all_valid_results() -> None:
    movies = parse_discover(_DISCOVER_BODY)
    assert [m.id for m in movies] == [1, 2]
    assert parse_discover({}) == []


def test_parse_genres_skips_malformed() -> None:
    genres = parse_genres(_GENRES_BODY)
    assert [(g.id, g.name) for g in genres] == [(28, "动作"), (18, "剧情")]


async def test_discover_sends_genres_and_vote_floor() -> None:
    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["path"] = request.url.path
        seen["query"] = dict(request.url.params)
        return httpx.Response(200, json=_DISCOVER_BODY)

    c = _client(httpx.MockTransport(handler), discover_min_votes=150)
    movies = await c.discover_movies([28, 18], "vote_average.desc", page=2)
    assert [m.id for m in movies] == [1, 2]
    assert seen["path"].endswith("/discover/movie")
    assert seen["query"]["with_genres"] == "28,18"
    assert seen["query"]["sort_by"] == "vote_average.desc"
    assert seen["query"]["page"] == "2"
    assert seen["query"]["vote_count.gte"] == "150"  # score sort → vote floor


async def test_discover_popular_omits_genres_and_vote_floor() -> None:
    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["query"] = dict(request.url.params)
        return httpx.Response(200, json={"results": []})

    c = _client(httpx.MockTransport(handler))
    assert await c.discover_movies([], "popularity.desc") == []
    assert "with_genres" not in seen["query"]
    assert "vote_count.gte" not in seen["query"]


async def test_get_movie_by_id() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/movie/27205")
        return httpx.Response(
            200, json={"id": 27205, "title": "盗梦空间", "vote_average": 8.4}
        )

    c = _client(httpx.MockTransport(handler))
    m = await c.get_movie(27205)
    assert m is not None and m.id == 27205 and m.title == "盗梦空间"


async def test_get_movie_404_returns_none() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, json={"status_code": 34})

    c = _client(httpx.MockTransport(handler))
    assert await c.get_movie(999999) is None


async def test_genres_call() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/genre/movie/list")
        return httpx.Response(200, json=_GENRES_BODY)

    c = _client(httpx.MockTransport(handler))
    genres = await c.genres()
    assert (genres[0].id, genres[0].name) == (28, "动作")


# ---- thumbnail download (backend proxy) ------------------------------------


async def test_fetch_thumb_downloads_image() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        # Browse thumbnails use the smaller bucket, not the full poster size.
        assert request.url.path.endswith("/w342/x.jpg")
        return httpx.Response(
            200,
            content=b"\xff\xd8\xff" + b"z" * 2000,
            headers={"content-type": "image/jpeg"},
        )

    c = _client(httpx.MockTransport(handler))
    got = await c.fetch_thumb("/x.jpg")
    assert got is not None
    assert got[1] == "image/jpeg"
    assert len(got[0]) > 1000


async def test_fetch_thumb_non_image_returns_none() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200, content=b"<html>", headers={"content-type": "text/html"}
        )

    c = _client(httpx.MockTransport(handler))
    assert await c.fetch_thumb("/x.jpg") is None
