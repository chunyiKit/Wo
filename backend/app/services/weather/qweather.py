"""QWeather (和风天气) provider — REST client for current conditions.

Mirrors `app.services.ai.kimi.KimiClient`: a frozen dataclass built
`from_settings`, a `configured` guard, and httpx calls wrapped so any transport
failure surfaces as the module's domain error (`WeatherError`).

Two best-effort calls per query:
- `weather/now`  → temperature, humidity, precipitation, sky condition (required).
- `indices/1d?type=5` → UV index (optional; failure leaves `uv_index=None`).

The request/response shaping is split into pure functions (`parse_now`,
`parse_uv`) so they're unit-testable without a network.

Auth / host note: the free developer tier uses an API key as a query parameter
against a configurable host (default `https://devapi.qweather.com/v7`). Paid /
JWT setups use a dedicated host — switch via `qweather_base_url`. Verify the
exact host & auth against the platform's current docs before going live.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

import httpx

from app.services.weather.types import (
    WeatherError,
    WeatherNotConfiguredError,
    WeatherSnapshot,
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


def parse_now(body: dict[str, Any]) -> dict[str, Any]:
    """Extract the fields we care about from a `weather/now` response. Pure.

    Raises `WeatherError` when the body has no usable `now` block (QWeather
    signals success with `code == "200"`).
    """
    code = str(body.get("code", ""))
    now = body.get("now")
    if code != "200" or not isinstance(now, dict):
        raise WeatherError(f"QWeather weather/now 异常: code={code or '?'}")
    return {
        "temp_c": _to_float(now.get("temp")),
        "feels_like_c": _to_float(now.get("feelsLike")),
        "condition": now.get("text") or None,
        "icon": now.get("icon") or None,
        "humidity_pct": _to_int(now.get("humidity")),
        "precip_mm": _to_float(now.get("precip")),
        "pressure_hpa": _to_float(now.get("pressure")),
        "visibility_km": _to_float(now.get("vis")),
        "cloud_pct": _to_int(now.get("cloud")),
        "dew_point_c": _to_float(now.get("dew")),
        "wind_dir": now.get("windDir") or None,
        "wind_scale": now.get("windScale") or None,
        "wind_speed_kmh": _to_float(now.get("windSpeed")),
        "wind_deg": _to_float(now.get("wind360")),
        "observed_at": body.get("updateTime") or now.get("obsTime"),
    }


def parse_uv(body: dict[str, Any]) -> float | None:
    """Extract the UV index from an `indices/1d?type=5` response. Pure.

    Returns None on any shape we don't recognize — UV is optional.
    """
    if str(body.get("code", "")) != "200":
        return None
    daily = body.get("daily")
    if isinstance(daily, list) and daily:
        return _to_float(daily[0].get("level"))
    return None


@dataclass(frozen=True)
class QWeatherClient:
    api_key: str
    base_url: str
    timeout_seconds: float
    # Injectable for tests (httpx.MockTransport). None → real network transport.
    transport: httpx.AsyncBaseTransport | None = None

    @classmethod
    def from_settings(cls, settings: Settings) -> QWeatherClient:
        return cls(
            api_key=settings.qweather_api_key,
            base_url=settings.qweather_base_url.rstrip("/"),
            timeout_seconds=settings.weather_timeout_seconds,
        )

    @property
    def configured(self) -> bool:
        return bool(self.api_key)

    async def get_now(self, lat: float, lon: float) -> WeatherSnapshot:
        if not self.configured:
            raise WeatherNotConfiguredError("QWeather 未配置 API Key")
        # QWeather expects "longitude,latitude" order.
        location = f"{lon:.4f},{lat:.4f}"
        async with httpx.AsyncClient(
            timeout=self.timeout_seconds, transport=self.transport
        ) as http:
            now_fields = await self._fetch_now(http, location)
            uv = await self._fetch_uv(http, location)
        return WeatherSnapshot(location=location, uv_index=uv, **now_fields)

    async def _fetch_now(
        self, http: httpx.AsyncClient, location: str
    ) -> dict[str, Any]:
        url = f"{self.base_url}/weather/now"
        params = {"location": location, "key": self.api_key}
        try:
            resp = await http.get(url, params=params)
        except httpx.HTTPError as exc:
            raise WeatherError(f"QWeather 请求失败: {exc}") from exc
        if resp.status_code != 200:
            raise WeatherError(f"QWeather 返回错误: {resp.status_code}")
        try:
            body = resp.json()
        except ValueError as exc:
            raise WeatherError("QWeather 返回非 JSON 内容") from exc
        return parse_now(body)

    async def _fetch_uv(self, http: httpx.AsyncClient, location: str) -> float | None:
        """Best-effort UV fetch. Never raises — UV is optional context."""
        url = f"{self.base_url}/indices/1d"
        params = {"location": location, "type": "5", "key": self.api_key}
        try:
            resp = await http.get(url, params=params)
            if resp.status_code != 200:
                return None
            return parse_uv(resp.json())
        except (httpx.HTTPError, ValueError) as exc:
            logger.info("QWeather UV fetch failed: %s", exc)
            return None


__all__ = ["QWeatherClient", "parse_now", "parse_uv"]
