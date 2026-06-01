"""Weather module entry point — provider selection + a small in-process cache.

Plugins use this module, not a vendor client directly:

    from app.services.weather import get_weather, WeatherError

    try:
        snap = await get_weather(lat, lon)
    except WeatherError:
        snap = None  # degrade gracefully — weather is optional context

Swapping providers is a config change (`weather_provider`), not a code change in
the calling plugin.

Caching: weather changes slowly and the provider's free tier is rate-limited, so
results are cached per quantized location for `weather_cache_ttl_seconds`. The
cache is a process-local dict — fine for the project's low concurrency; a
multi-process deployment would each keep their own (acceptable for weather).
"""

from __future__ import annotations

import time

from app.core.config import Settings, settings
from app.services.weather.qweather import QWeatherClient
from app.services.weather.types import (
    WeatherError,
    WeatherProvider,
    WeatherSnapshot,
)

# Round coordinates to ~1km so nearby lookups share a cache entry.
_COORD_QUANTIZE = 2  # decimal places

# location-key -> (monotonic_expiry, snapshot)
_cache: dict[str, tuple[float, WeatherSnapshot]] = {}


def get_weather_provider(cfg: Settings | None = None) -> WeatherProvider:
    """Build the configured provider. `cfg` is injectable for tests; defaults to
    the process settings singleton."""
    cfg = cfg or settings
    provider = cfg.weather_provider.lower()
    if provider == "qweather":
        return QWeatherClient.from_settings(cfg)
    raise WeatherError(f"不支持的 weather provider: {cfg.weather_provider!r}")


def _cache_key(lat: float, lon: float) -> str:
    return f"{round(lat, _COORD_QUANTIZE)},{round(lon, _COORD_QUANTIZE)}"


def clear_weather_cache() -> None:
    """Drop all cached snapshots — used by tests for isolation."""
    _cache.clear()


async def get_weather(
    lat: float,
    lon: float,
    *,
    provider: WeatherProvider | None = None,
    use_cache: bool = True,
) -> WeatherSnapshot:
    """Return current weather at a location, served from cache within the TTL.

    Pass `provider` to override (e.g. an already-built client); otherwise the one
    selected by settings is used. Raises `WeatherNotConfiguredError` when the
    provider has no key, `WeatherError` on failure — callers should catch and
    degrade rather than propagate to the user.
    """
    key = _cache_key(lat, lon)
    if use_cache:
        hit = _cache.get(key)
        if hit is not None and hit[0] > time.monotonic():
            return hit[1]

    prov = provider or get_weather_provider()
    snapshot = await prov.get_now(lat, lon)

    if use_cache:
        ttl = settings.weather_cache_ttl_seconds
        _cache[key] = (time.monotonic() + ttl, snapshot)
    return snapshot


__all__ = ["get_weather", "get_weather_provider", "clear_weather_cache"]
