"""Movie AI enrichment — fills a movie's intro / rating / poster from its title.

`enrich_movie` is the background task scheduled after a movie is created (and by
the manual re-enrich route). It opens its own DB session (the request's is gone
by the time it runs), asks the configured AI provider for a JSON blob, best-effort
downloads the poster, and updates the row's AI fields + `ai_status`.

Design notes:
- The poster comes from a Douban CDN URL the model recalls. Douban blocks
  hot-linking, so the download sends a browser UA + a `movie.douban.com`
  Referer — verified to return the real image. A poster failure does NOT fail
  the whole enrichment (intro/rating still save); only an AI/parse failure does.
- All exceptions are swallowed into `ai_status="failed"` so a flaky model or
  network never crashes the background task.
"""

from __future__ import annotations

import json
import logging
from typing import Any
from uuid import UUID

import httpx

from app.core.database import async_session_maker
from app.core.storage import storage
from app.plugins.movie.models import MAX_INTRO_LEN, Movie
from app.services.ai import AiError, ai_complete_text

logger = logging.getLogger(__name__)

# Generous budget: K2-class thinking models spend tokens reasoning before the
# JSON answer, so a small cap truncates mid-output (empty content).
_MAX_TOKENS = 3000
_POSTER_TIMEOUT = 20.0
_POSTER_MIN_BYTES = 1000
_POSTER_MAX_BYTES = 10 * 1024 * 1024

_SYSTEM_PROMPT = "你是电影资料助手。只输出一个 JSON 对象，不要任何额外文字、解释或代码块标记。"

# Douban serves posters only to requests that look like a browser coming from
# its own site; without these headers the CDN returns 418 / empty.
_POSTER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    ),
    "Referer": "https://movie.douban.com/",
}


def _build_prompt(title: str) -> str:
    return (
        "根据电影片名返回一个 JSON 对象，字段如下：\n"
        '"intro"：100到150字的中文剧情简介；\n'
        '"douban_rating"：豆瓣评分数字（如 9.7），不确定填 null；\n'
        '"poster_url"：该电影的豆瓣海报图片直链 URL（形如 '
        "https://img9.doubanio.com/view/photo/s_ratio_poster/public/pXXXX.jpg），不确定填 null。\n"
        f"片名：{title}"
    )


def _strip_fence(text: str) -> str:
    """Tolerate a model that wraps JSON in a ```json fence despite instructions."""
    s = text.strip()
    if s.startswith("```"):
        s = s.split("\n", 1)[1] if "\n" in s else s
        s = s.rsplit("```", 1)[0]
    return s.strip()


def _parse_rating(value: Any) -> float | None:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


async def _download_poster(url: str) -> tuple[bytes, str] | None:
    """Fetch the poster bytes, or None if it isn't a usable image."""
    if not url or not url.startswith("http"):
        return None
    try:
        async with httpx.AsyncClient(
            timeout=_POSTER_TIMEOUT, follow_redirects=True
        ) as http:
            resp = await http.get(url, headers=_POSTER_HEADERS)
    except httpx.HTTPError as exc:
        logger.info("poster download failed: %s", exc)
        return None
    if resp.status_code != 200:
        logger.info("poster download non-200: %s", resp.status_code)
        return None
    content_type = (resp.headers.get("content-type") or "").split(";")[0].strip()
    if not content_type.startswith("image/"):
        logger.info("poster download not an image: %s", content_type)
        return None
    data = resp.content
    if not (_POSTER_MIN_BYTES <= len(data) <= _POSTER_MAX_BYTES):
        logger.info("poster size out of range: %d bytes", len(data))
        return None
    return data, content_type


async def enrich_movie(movie_id: UUID) -> None:
    """Background task: enrich one movie from its title. Never raises."""
    async with async_session_maker() as session:
        movie = await session.get(Movie, movie_id)
        if movie is None:
            return
        title = movie.title.strip()
        try:
            result = await ai_complete_text(
                system=_SYSTEM_PROMPT,
                user=_build_prompt(title),
                max_tokens=_MAX_TOKENS,
            )
            data = json.loads(_strip_fence(result.content))
            if not isinstance(data, dict):
                raise AiError("AI 返回的不是 JSON 对象")
        except (AiError, json.JSONDecodeError, ValueError) as exc:
            logger.warning("movie enrich failed for %s: %s", movie_id, exc)
            movie.ai_status = "failed"
            session.add(movie)
            await session.commit()
            return

        intro = data.get("intro")
        if isinstance(intro, str) and intro.strip():
            movie.intro = intro.strip()[:MAX_INTRO_LEN]
        movie.douban_rating = _parse_rating(data.get("douban_rating"))

        poster_url = data.get("poster_url")
        if isinstance(poster_url, str):
            downloaded = await _download_poster(poster_url)
            if downloaded is not None:
                content, content_type = downloaded
                key = f"movie-posters/{movie.family_id}/{movie.id}.jpg"
                await storage.put(key, content, content_type)
                movie.poster_storage_key = key
                movie.poster_content_type = content_type
                movie.poster_version += 1

        movie.ai_status = "ready"
        session.add(movie)
        await session.commit()


__all__ = ["enrich_movie"]
