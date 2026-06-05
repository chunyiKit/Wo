"""Movie plugin tests — CRUD, watched toggling, ordering, and the home preview."""

import uuid

import pytest
from httpx import AsyncClient

LAOCHEN = "019000a0-1100-7000-8000-000000000001"

MOVIE_BASE = "/api/v1/families/{fid}/plugins/movie/movies"


async def _create_family(client: AsyncClient) -> str:
    resp = await client.post(
        "/api/v1/families", json={"name": f"测试-{uuid.uuid4().hex[:6]}"}
    )
    return resp.json()["data"]["id"]


async def test_create_and_list(client: AsyncClient) -> None:
    fid = await _create_family(client)
    create = await client.post(
        MOVIE_BASE.format(fid=fid),
        json={"title": "瞬息全宇宙", "note": "听说很奇怪"},
    )
    assert create.status_code == 201, create.text
    created = create.json()["data"]
    assert created["title"] == "瞬息全宇宙"
    assert created["note"] == "听说很奇怪"
    assert created["watched"] is False
    assert created["watched_at"] is None

    listed = await client.get(MOVIE_BASE.format(fid=fid))
    assert listed.status_code == 200
    data = listed.json()["data"]
    assert len(data) == 1


async def test_empty_title_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    resp = await client.post(MOVIE_BASE.format(fid=fid), json={"title": "   "})
    assert resp.status_code == 400


async def test_watched_toggle_stamps_timestamp(client: AsyncClient) -> None:
    """Flipping `watched` true sets `watched_at`; flipping back to false clears it.
    Re-confirming `watched=true` does NOT reset the original timestamp."""
    fid = await _create_family(client)
    mid = (
        await client.post(MOVIE_BASE.format(fid=fid), json={"title": "看完了再说"})
    ).json()["data"]["id"]

    # Flip on.
    flipped = await client.put(
        f"{MOVIE_BASE.format(fid=fid)}/{mid}", json={"watched": True}
    )
    assert flipped.json()["data"]["watched"] is True
    first_ts = flipped.json()["data"]["watched_at"]
    assert first_ts is not None

    # Idempotent re-flip preserves the original timestamp.
    again = await client.put(
        f"{MOVIE_BASE.format(fid=fid)}/{mid}", json={"watched": True}
    )
    assert again.json()["data"]["watched_at"] == first_ts

    # Flip off clears it.
    off = await client.put(
        f"{MOVIE_BASE.format(fid=fid)}/{mid}", json={"watched": False}
    )
    assert off.json()["data"]["watched"] is False
    assert off.json()["data"]["watched_at"] is None


async def test_list_filter_by_watched(client: AsyncClient) -> None:
    fid = await _create_family(client)
    ids = []
    for title in ("第一部", "第二部", "第三部"):
        ids.append(
            (
                await client.post(MOVIE_BASE.format(fid=fid), json={"title": title})
            ).json()["data"]["id"]
        )
    # Mark middle one as watched.
    await client.put(f"{MOVIE_BASE.format(fid=fid)}/{ids[1]}", json={"watched": True})

    want = await client.get(MOVIE_BASE.format(fid=fid), params={"watched": "false"})
    assert [m["title"] for m in want.json()["data"]] == ["第三部", "第一部"]

    seen = await client.get(MOVIE_BASE.format(fid=fid), params={"watched": "true"})
    assert [m["title"] for m in seen.json()["data"]] == ["第二部"]


async def test_delete(client: AsyncClient) -> None:
    fid = await _create_family(client)
    mid = (
        await client.post(MOVIE_BASE.format(fid=fid), json={"title": "删除我"})
    ).json()["data"]["id"]
    resp = await client.delete(f"{MOVIE_BASE.format(fid=fid)}/{mid}")
    assert resp.status_code == 200
    listed = await client.get(MOVIE_BASE.format(fid=fid))
    assert listed.json()["data"] == []


# ---- preview ---------------------------------------------------------------


@pytest.fixture
def _preview_imports():
    from app.core.database import async_session_maker
    from app.models.plugin import InstalledPlugin
    from app.plugins.movie.service import preview_hook

    return async_session_maker, InstalledPlugin, preview_hook


async def test_preview_empty(client: AsyncClient, _preview_imports) -> None:
    async_session_maker, InstalledPlugin, preview_hook = _preview_imports
    fid = await _create_family(client)
    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="movie")
    async with async_session_maker() as session:
        preview = await preview_hook(session, ip, uuid.UUID(LAOCHEN))
    assert preview.primary == "还没想看的"


async def test_preview_with_want_to_watch(client: AsyncClient, _preview_imports) -> None:
    async_session_maker, InstalledPlugin, preview_hook = _preview_imports
    fid = await _create_family(client)
    await client.post(MOVIE_BASE.format(fid=fid), json={"title": "旧片"})
    await client.post(MOVIE_BASE.format(fid=fid), json={"title": "最新加的"})

    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="movie")
    async with async_session_maker() as session:
        preview = await preview_hook(session, ip, uuid.UUID(LAOCHEN))
    assert preview.primary == "最新加的"
    assert preview.secondary == "还有 2 部想看"


async def test_preview_all_watched(client: AsyncClient, _preview_imports) -> None:
    """If every recorded movie is watched, the card celebrates instead of going empty."""
    async_session_maker, InstalledPlugin, preview_hook = _preview_imports
    fid = await _create_family(client)
    mid = (
        await client.post(MOVIE_BASE.format(fid=fid), json={"title": "唯一一部"})
    ).json()["data"]["id"]
    await client.put(f"{MOVIE_BASE.format(fid=fid)}/{mid}", json={"watched": True})

    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="movie")
    async with async_session_maker() as session:
        preview = await preview_hook(session, ip, uuid.UUID(LAOCHEN))
    assert preview.primary == "都看过了"
    assert preview.secondary == "看过 1 部"


# ---- TMDB enrichment -------------------------------------------------------

from app.plugins.movie.enrich import enrich_movie  # noqa: E402
from app.services.tmdb import TmdbError, TmdbGenre, TmdbMovie  # noqa: E402

_FAKE_MATCH = TmdbMovie(
    id=27205,
    title="盗梦空间",
    original_title="Inception",
    overview="一段来自 TMDB 的中文剧情简介，用于测试 enrichment 是否把简介正确写入数据库。",
    poster_path="/inception.jpg",
    release_date="2010-07-15",
    vote_average=8.4,
    vote_count=34000,
)


def _install_fake_search(monkeypatch, *, match=_FAKE_MATCH, raises: bool = False):
    """Replace the combined movie+TV search inside movie.enrich with a stub."""
    async def fake(query):
        if raises:
            raise TmdbError("boom")
        return match

    monkeypatch.setattr("app.plugins.movie.enrich.search_title", fake)


def _install_fake_poster(monkeypatch, *, ok: bool = True):
    async def fake(url):
        return (b"\xff\xd8\xff" + b"x" * 3000, "image/jpeg") if ok else None

    monkeypatch.setattr("app.plugins.movie.enrich._download_poster", fake)


async def test_create_sets_pending_status(client: AsyncClient) -> None:
    fid = await _create_family(client)
    resp = await client.post(MOVIE_BASE.format(fid=fid), json={"title": "盗梦空间"})
    assert resp.status_code == 201
    # Saving returns immediately; enrichment happens in the background.
    assert resp.json()["data"]["ai_status"] == "pending"


async def test_enrich_success_fills_fields_and_poster(
    client: AsyncClient, monkeypatch
) -> None:
    fid = await _create_family(client)
    mid = (
        await client.post(MOVIE_BASE.format(fid=fid), json={"title": "肖申克的救赎"})
    ).json()["data"]["id"]

    _install_fake_search(monkeypatch)
    _install_fake_poster(monkeypatch, ok=True)
    await enrich_movie(uuid.UUID(mid))

    got = (await client.get(MOVIE_BASE.format(fid=fid))).json()["data"][0]
    assert got["ai_status"] == "ready"
    assert got["intro"] == _FAKE_MATCH.overview
    assert got["tmdb_rating"] == 8.4
    assert got["poster_url"] is not None
    assert "/poster?v=" in got["poster_url"]

    # The poster bytes are served (LocalStorage streams inline in tests).
    poster = await client.get(f"{MOVIE_BASE.format(fid=fid)}/{mid}/poster")
    assert poster.status_code == 200
    assert poster.headers["content-type"].startswith("image/")
    assert len(poster.content) > 1000


async def test_enrich_tmdb_error_sets_failed(
    client: AsyncClient, monkeypatch
) -> None:
    fid = await _create_family(client)
    mid = (
        await client.post(MOVIE_BASE.format(fid=fid), json={"title": "无名电影"})
    ).json()["data"]["id"]

    _install_fake_search(monkeypatch, raises=True)
    await enrich_movie(uuid.UUID(mid))

    got = (await client.get(MOVIE_BASE.format(fid=fid))).json()["data"][0]
    assert got["ai_status"] == "failed"
    assert got["intro"] is None


async def test_enrich_no_match_sets_failed(
    client: AsyncClient, monkeypatch
) -> None:
    """A title TMDB doesn't know → failed (the user can fix the title and retry)."""
    fid = await _create_family(client)
    mid = (
        await client.post(MOVIE_BASE.format(fid=fid), json={"title": "完全不存在的片"})
    ).json()["data"]["id"]

    _install_fake_search(monkeypatch, match=None)
    await enrich_movie(uuid.UUID(mid))

    got = (await client.get(MOVIE_BASE.format(fid=fid))).json()["data"][0]
    assert got["ai_status"] == "failed"
    assert got["tmdb_rating"] is None


_FAKE_TV_MATCH = TmdbMovie(
    id=53052,
    title="来自新世界",
    original_title="新世界より",
    overview="一段来自 TMDB 的剧集简介，用于测试电视剧也能被补充。",
    poster_path="/tv.jpg",
    release_date="2012-09-29",
    vote_average=8.3,
    media_type="tv",
)


async def test_enrich_finds_tv_series_via_multi_search(
    client: AsyncClient, monkeypatch
) -> None:
    """A TV series (e.g.「来自新世界」, no movie match) is found via the combined
    movie+TV search and enriches normally — the watch-list isn't films-only."""
    fid = await _create_family(client)
    mid = (
        await client.post(MOVIE_BASE.format(fid=fid), json={"title": "来自新世界"})
    ).json()["data"]["id"]

    _install_fake_search(monkeypatch, match=_FAKE_TV_MATCH)
    _install_fake_poster(monkeypatch, ok=True)
    await enrich_movie(uuid.UUID(mid))

    got = (await client.get(MOVIE_BASE.format(fid=fid))).json()["data"][0]
    assert got["ai_status"] == "ready"
    assert got["intro"] == _FAKE_TV_MATCH.overview
    assert got["tmdb_rating"] == 8.3
    assert got["poster_url"] is not None


async def test_enrich_poster_fail_still_ready(
    client: AsyncClient, monkeypatch
) -> None:
    """A poster download failure must not fail the whole enrichment — intro and
    rating still save, status is ready, poster_url stays null."""
    fid = await _create_family(client)
    mid = (
        await client.post(MOVIE_BASE.format(fid=fid), json={"title": "千与千寻"})
    ).json()["data"]["id"]

    _install_fake_search(monkeypatch)
    _install_fake_poster(monkeypatch, ok=False)
    await enrich_movie(uuid.UUID(mid))

    got = (await client.get(MOVIE_BASE.format(fid=fid))).json()["data"][0]
    assert got["ai_status"] == "ready"
    assert got["intro"] == _FAKE_MATCH.overview
    assert got["poster_url"] is None


async def test_poster_404_when_absent(client: AsyncClient) -> None:
    fid = await _create_family(client)
    mid = (
        await client.post(MOVIE_BASE.format(fid=fid), json={"title": "没有海报"})
    ).json()["data"]["id"]
    resp = await client.get(f"{MOVIE_BASE.format(fid=fid)}/{mid}/poster")
    assert resp.status_code == 404


async def test_reenrich_endpoint_resets_pending(client: AsyncClient) -> None:
    fid = await _create_family(client)
    mid = (
        await client.post(MOVIE_BASE.format(fid=fid), json={"title": "重试片"})
    ).json()["data"]["id"]
    resp = await client.post(f"{MOVIE_BASE.format(fid=fid)}/{mid}/enrich")
    assert resp.status_code == 200
    assert resp.json()["data"]["ai_status"] == "pending"


# ---- 片库 (TMDB discover) ---------------------------------------------------

DISCOVER_BASE = "/api/v1/families/{fid}/plugins/movie/discover"


def _install_fake_get_movie(monkeypatch, *, match=_FAKE_MATCH):
    """Stub the by-id lookups used by BOTH the from_tmdb route (get_movie) and the
    background enrich (get_by_id), so adding from 片库 is deterministic end-to-end."""
    async def fake_route(tmdb_id):
        return match

    async def fake_enrich(tmdb_id, media_type="movie"):
        return match

    monkeypatch.setattr("app.plugins.movie.routes.get_movie", fake_route)
    monkeypatch.setattr("app.plugins.movie.enrich.get_by_id", fake_enrich)


async def test_discover_genres(client: AsyncClient, monkeypatch) -> None:
    fid = await _create_family(client)

    async def fake_genres():
        return [TmdbGenre(id=28, name="动作"), TmdbGenre(id=18, name="剧情")]

    monkeypatch.setattr("app.plugins.movie.routes.get_genres", fake_genres)
    resp = await client.get(f"{DISCOVER_BASE.format(fid=fid)}/genres")
    assert resp.status_code == 200
    assert resp.json()["data"] == [
        {"id": 28, "name": "动作"},
        {"id": 18, "name": "剧情"},
    ]


async def test_discover_lists_with_poster_and_added_flag(
    client: AsyncClient, monkeypatch
) -> None:
    fid = await _create_family(client)

    # Add 27205 first so discover flags it as already in the family's list.
    _install_fake_get_movie(monkeypatch)
    _install_fake_poster(monkeypatch, ok=True)
    await client.post(
        f"{MOVIE_BASE.format(fid=fid)}/from_tmdb", json={"tmdb_id": 27205}
    )

    async def fake_discover(*, genre_ids, sort, page):
        return [
            _FAKE_MATCH,  # id 27205 → already added
            TmdbMovie(
                id=99, title="新片", overview="简介", poster_path="/x.jpg",
                vote_average=7.7,
            ),
        ]

    monkeypatch.setattr("app.plugins.movie.routes.discover_movies", fake_discover)
    resp = await client.get(
        DISCOVER_BASE.format(fid=fid), params={"genres": "28,18", "sort": "rating"}
    )
    assert resp.status_code == 200
    by_id = {c["tmdb_id"]: c for c in resp.json()["data"]}
    assert by_id[27205]["already_added"] is True
    assert by_id[99]["already_added"] is False
    assert by_id[99]["title"] == "新片"
    # poster_url now points at the backend thumbnail proxy (path url-encoded).
    assert "/discover/poster?path=" in by_id[99]["poster_url"]
    assert "%2Fx.jpg" in by_id[99]["poster_url"]


async def test_add_from_tmdb_creates_dedups(
    client: AsyncClient, monkeypatch
) -> None:
    fid = await _create_family(client)
    _install_fake_get_movie(monkeypatch)
    _install_fake_poster(monkeypatch, ok=True)

    resp = await client.post(
        f"{MOVIE_BASE.format(fid=fid)}/from_tmdb", json={"tmdb_id": 27205}
    )
    assert resp.status_code == 201
    data = resp.json()["data"]
    assert data["title"] == _FAKE_MATCH.title
    assert data["tmdb_rating"] == 8.4
    assert data["intro"] == _FAKE_MATCH.overview  # pre-filled from TMDB

    # The background enrich ran during the request → now ready with a poster.
    got = (await client.get(MOVIE_BASE.format(fid=fid))).json()["data"][0]
    assert got["ai_status"] == "ready"
    assert got["poster_url"] is not None

    # Re-adding the same TMDB id is rejected.
    dup = await client.post(
        f"{MOVIE_BASE.format(fid=fid)}/from_tmdb", json={"tmdb_id": 27205}
    )
    assert dup.status_code == 400


async def test_add_from_tmdb_not_found(client: AsyncClient, monkeypatch) -> None:
    fid = await _create_family(client)

    async def fake(tmdb_id):
        return None

    monkeypatch.setattr("app.plugins.movie.routes.get_movie", fake)
    resp = await client.post(
        f"{MOVIE_BASE.format(fid=fid)}/from_tmdb", json={"tmdb_id": 1}
    )
    assert resp.status_code == 404


async def test_discover_poster_proxies_bytes(
    client: AsyncClient, monkeypatch
) -> None:
    fid = await _create_family(client)

    async def fake_thumb(path):
        assert path == "/x.jpg"
        return (b"\xff\xd8\xff" + b"y" * 2000, "image/jpeg")

    monkeypatch.setattr("app.plugins.movie.routes.fetch_poster_thumb", fake_thumb)
    resp = await client.get(
        f"{DISCOVER_BASE.format(fid=fid)}/poster", params={"path": "/x.jpg"}
    )
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("image/")
    assert "max-age" in resp.headers.get("cache-control", "")
    assert len(resp.content) > 1000


async def test_discover_poster_rejects_bad_path(
    client: AsyncClient, monkeypatch
) -> None:
    """SSRF-ish / malformed paths are rejected before any fetch happens."""
    fid = await _create_family(client)
    calls = {"n": 0}

    async def fake_thumb(path):
        calls["n"] += 1
        return None

    monkeypatch.setattr("app.plugins.movie.routes.fetch_poster_thumb", fake_thumb)
    for bad in [
        "/../etc/passwd",
        "http://evil.example/a.jpg",
        "/a.txt",
        "/a.jpg/b",
        "abc.jpg",
    ]:
        r = await client.get(
            f"{DISCOVER_BASE.format(fid=fid)}/poster", params={"path": bad}
        )
        assert r.status_code == 400, bad
    assert calls["n"] == 0


async def test_discover_poster_404_when_unavailable(
    client: AsyncClient, monkeypatch
) -> None:
    fid = await _create_family(client)

    async def fake_thumb(path):
        return None  # image host unreachable / not an image

    monkeypatch.setattr("app.plugins.movie.routes.fetch_poster_thumb", fake_thumb)
    resp = await client.get(
        f"{DISCOVER_BASE.format(fid=fid)}/poster", params={"path": "/x.jpg"}
    )
    assert resp.status_code == 404
