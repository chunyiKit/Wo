"""Weather module tests — pure parsers, the not-configured guard, provider
selection, an end-to-end call against a mocked transport, and the service cache."""

import httpx
import pytest

from app.core.config import Settings
from app.services.weather import (
    WeatherError,
    WeatherNotConfiguredError,
    clear_weather_cache,
    get_weather,
    get_weather_provider,
)
from app.services.weather.qweather import QWeatherClient, parse_now, parse_uv
from app.services.weather.types import WeatherSnapshot


@pytest.fixture(autouse=True)
def _clear_cache():
    clear_weather_cache()
    yield
    clear_weather_cache()


# ---- pure parsers ----------------------------------------------------------


def test_parse_now_extracts_fields() -> None:
    body = {
        "code": "200",
        "updateTime": "2026-06-01T12:00+08:00",
        "now": {"temp": "24", "humidity": "55", "precip": "0.0", "text": "多云"},
    }
    fields = parse_now(body)
    assert fields["temp_c"] == 24.0
    assert fields["humidity_pct"] == 55
    assert fields["precip_mm"] == 0.0
    assert fields["condition"] == "多云"
    assert fields["observed_at"] == "2026-06-01T12:00+08:00"


def test_parse_now_bad_code_raises() -> None:
    with pytest.raises(WeatherError):
        parse_now({"code": "404", "now": None})


def test_parse_uv_extracts_level() -> None:
    body = {"code": "200", "daily": [{"type": "5", "name": "紫外线指数", "level": "4"}]}
    assert parse_uv(body) == 4.0


def test_parse_uv_tolerates_missing() -> None:
    assert parse_uv({"code": "404"}) is None
    assert parse_uv({"code": "200", "daily": []}) is None


# ---- provider selection / not configured -----------------------------------


def test_get_provider_qweather() -> None:
    cfg = Settings(weather_provider="qweather", qweather_api_key="k")
    provider = get_weather_provider(cfg)
    assert isinstance(provider, QWeatherClient)
    assert provider.configured is True


def test_get_provider_unknown_raises() -> None:
    with pytest.raises(WeatherError):
        get_weather_provider(Settings(weather_provider="nope"))


async def test_get_now_unconfigured_raises() -> None:
    client = QWeatherClient(api_key="", base_url="https://x/v7", timeout_seconds=5)
    with pytest.raises(WeatherNotConfiguredError):
        await client.get_now(31.2, 121.5)


# ---- end-to-end against a mocked transport ---------------------------------


def _routing_handler(now_body, uv_body):
    def handler(request: httpx.Request) -> httpx.Response:
        if "weather/now" in request.url.path:
            return httpx.Response(200, json=now_body)
        if "indices/1d" in request.url.path:
            return httpx.Response(200, json=uv_body)
        return httpx.Response(404, json={})

    return httpx.MockTransport(handler)


async def test_get_now_success_combines_now_and_uv() -> None:
    now_body = {
        "code": "200",
        "updateTime": "2026-06-01T12:00+08:00",
        "now": {"temp": "24", "humidity": "55", "precip": "0.0", "text": "多云"},
    }
    uv_body = {"code": "200", "daily": [{"type": "5", "level": "4"}]}
    client = QWeatherClient(
        api_key="k",
        base_url="https://devapi.qweather.com/v7",
        timeout_seconds=5,
        transport=_routing_handler(now_body, uv_body),
    )
    snap = await client.get_now(31.2304, 121.4737)
    assert snap.temp_c == 24.0
    assert snap.humidity_pct == 55
    assert snap.condition == "多云"
    assert snap.uv_index == 4.0
    # QWeather expects "lon,lat" order.
    assert snap.location == "121.4737,31.2304"


async def test_get_now_uv_failure_degrades_to_none() -> None:
    now_body = {
        "code": "200",
        "now": {"temp": "20", "humidity": "60", "precip": "0.0", "text": "晴"},
    }

    def handler(request: httpx.Request) -> httpx.Response:
        if "weather/now" in request.url.path:
            return httpx.Response(200, json=now_body)
        return httpx.Response(500, json={})  # UV endpoint down

    client = QWeatherClient(
        api_key="k",
        base_url="https://x/v7",
        timeout_seconds=5,
        transport=httpx.MockTransport(handler),
    )
    snap = await client.get_now(10.0, 20.0)
    assert snap.condition == "晴"
    assert snap.uv_index is None  # optional context degrades, no crash


# ---- service cache ---------------------------------------------------------


async def test_service_caches_within_ttl() -> None:
    calls = {"n": 0}

    class _StubProvider:
        configured = True

        async def get_now(self, lat: float, lon: float) -> WeatherSnapshot:
            calls["n"] += 1
            return WeatherSnapshot(temp_c=22.0, condition="晴")

    stub = _StubProvider()
    a = await get_weather(31.23, 121.47, provider=stub)
    b = await get_weather(31.234, 121.472, provider=stub)  # same quantized cell
    assert a.temp_c == 22.0 and b.temp_c == 22.0
    assert calls["n"] == 1  # second lookup served from cache, no extra call
