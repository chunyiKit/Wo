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


# ---- AI enrichment ---------------------------------------------------------

import json  # noqa: E402

from app.plugins.movie.ai import enrich_movie  # noqa: E402
from app.services.ai import AiError, AiResult  # noqa: E402

_FAKE_JSON = {
    "intro": "一段一百到一百五十字的中文剧情简介，用于测试 AI 补充流程是否把简介正确写入数据库。",
    "douban_rating": 9.7,
    "poster_url": "https://img9.doubanio.com/view/photo/s_ratio_poster/public/p480747492.jpg",
}


def _install_fake_ai(monkeypatch, *, content: str | None = None, raises: bool = False):
    """Replace the AI call inside movie.ai with a deterministic stub."""
    async def fake(*, system=None, user="", max_tokens=None):
        if raises:
            raise AiError("boom")
        body = content if content is not None else json.dumps(_FAKE_JSON)
        return AiResult(content=body, model="kimi-k2.6", finish_reason="stop")

    monkeypatch.setattr("app.plugins.movie.ai.ai_complete_text", fake)


def _install_fake_poster(monkeypatch, *, ok: bool = True):
    async def fake(url):
        return (b"\xff\xd8\xff" + b"x" * 3000, "image/jpeg") if ok else None

    monkeypatch.setattr("app.plugins.movie.ai._download_poster", fake)


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

    _install_fake_ai(monkeypatch)
    _install_fake_poster(monkeypatch, ok=True)
    await enrich_movie(uuid.UUID(mid))

    got = (await client.get(MOVIE_BASE.format(fid=fid))).json()["data"][0]
    assert got["ai_status"] == "ready"
    assert got["intro"] == _FAKE_JSON["intro"]
    assert got["douban_rating"] == 9.7
    assert got["poster_url"] is not None
    assert "/poster?v=" in got["poster_url"]

    # The poster bytes are served (LocalStorage streams inline in tests).
    poster = await client.get(f"{MOVIE_BASE.format(fid=fid)}/{mid}/poster")
    assert poster.status_code == 200
    assert poster.headers["content-type"].startswith("image/")
    assert len(poster.content) > 1000


async def test_enrich_ai_failure_sets_failed(
    client: AsyncClient, monkeypatch
) -> None:
    fid = await _create_family(client)
    mid = (
        await client.post(MOVIE_BASE.format(fid=fid), json={"title": "无名电影"})
    ).json()["data"]["id"]

    _install_fake_ai(monkeypatch, raises=True)
    await enrich_movie(uuid.UUID(mid))

    got = (await client.get(MOVIE_BASE.format(fid=fid))).json()["data"][0]
    assert got["ai_status"] == "failed"
    assert got["intro"] is None


async def test_enrich_poster_fail_still_ready(
    client: AsyncClient, monkeypatch
) -> None:
    """A poster download failure must not fail the whole enrichment — intro and
    rating still save, status is ready, poster_url stays null."""
    fid = await _create_family(client)
    mid = (
        await client.post(MOVIE_BASE.format(fid=fid), json={"title": "千与千寻"})
    ).json()["data"]["id"]

    _install_fake_ai(monkeypatch)
    _install_fake_poster(monkeypatch, ok=False)
    await enrich_movie(uuid.UUID(mid))

    got = (await client.get(MOVIE_BASE.format(fid=fid))).json()["data"][0]
    assert got["ai_status"] == "ready"
    assert got["intro"] == _FAKE_JSON["intro"]
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
