"""TMDB image downloading — fetch a poster/thumbnail's bytes from the image CDN.

Shared by the movie plugin's enrichment (download + store a saved movie's poster)
and the 片库 thumbnail proxy (stream a browse thumbnail to clients). The image
host serves any client, so a plain browser UA suffices (no Referer dance, unlike
the old Douban CDN); responses are validated as real images within a size band
before use.
"""

from __future__ import annotations

import logging

import httpx

logger = logging.getLogger(__name__)

_DEFAULT_MIN_BYTES = 1000
_DEFAULT_MAX_BYTES = 10 * 1024 * 1024
_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
    ),
}


async def download_tmdb_image(
    url: str,
    *,
    timeout_seconds: float = 20.0,
    transport: httpx.AsyncBaseTransport | None = None,
    min_bytes: int = _DEFAULT_MIN_BYTES,
    max_bytes: int = _DEFAULT_MAX_BYTES,
) -> tuple[bytes, str] | None:
    """Download an image URL, returning (bytes, content_type) or None when it
    isn't a usable image (transport error, non-200, wrong type, out-of-band size).
    Never raises — callers degrade gracefully. `transport` is injectable for tests.
    """
    if not url or not url.startswith("http"):
        return None
    try:
        async with httpx.AsyncClient(
            timeout=timeout_seconds, transport=transport, follow_redirects=True
        ) as http:
            resp = await http.get(url, headers=_HEADERS)
    except httpx.HTTPError as exc:
        logger.info("tmdb image download failed: %s", exc)
        return None
    if resp.status_code != 200:
        logger.info("tmdb image non-200: %s", resp.status_code)
        return None
    content_type = (resp.headers.get("content-type") or "").split(";")[0].strip()
    if not content_type.startswith("image/"):
        logger.info("tmdb image not an image: %s", content_type)
        return None
    data = resp.content
    if not (min_bytes <= len(data) <= max_bytes):
        logger.info("tmdb image size out of range: %d bytes", len(data))
        return None
    return data, content_type


__all__ = ["download_tmdb_image"]
