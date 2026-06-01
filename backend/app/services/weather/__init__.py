"""Shared weather module — a provider-agnostic way for plugins to get the
current weather at a location.

Public surface (import from here, not the submodules):

    from app.services.weather import (
        get_weather,                          # call the provider (cached)
        WeatherSnapshot,                      # data type
        WeatherError, WeatherNotConfiguredError,  # failures to catch
        get_weather_provider,                 # the configured provider, if needed
    )

Currently backed by QWeather (和风天气); selecting another provider is a config
change (`weather_provider`), invisible to callers. This module supplies weather
data only — it holds no business logic.
"""

from app.services.weather.service import (
    clear_weather_cache,
    get_weather,
    get_weather_provider,
)
from app.services.weather.types import (
    WeatherError,
    WeatherNotConfiguredError,
    WeatherProvider,
    WeatherSnapshot,
)

__all__ = [
    "get_weather",
    "get_weather_provider",
    "clear_weather_cache",
    "WeatherProvider",
    "WeatherSnapshot",
    "WeatherError",
    "WeatherNotConfiguredError",
]
