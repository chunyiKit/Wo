"""Provider-agnostic types for the shared weather module.

`WeatherSnapshot` is the contract any provider speaks; `WeatherProvider` is the
structural type a concrete client (QWeather, …) satisfies. Callers (plugins)
depend only on these, never on a specific vendor's response shape.

This module is a pure data supplier: given a location it returns the current
weather. It contains NO business logic (no plant care reasoning, etc.) — that
belongs in the consuming plugin.
"""

from __future__ import annotations

from collections.abc import Awaitable
from dataclasses import dataclass
from typing import Protocol


class WeatherError(Exception):
    """A call to the weather provider failed (network, bad status, malformed body)."""


class WeatherNotConfiguredError(WeatherError):
    """The selected provider has no credentials. Callers should treat this as a
    feature-disabled signal rather than a transient failure (no point retrying)."""


@dataclass(frozen=True)
class WeatherSnapshot:
    """Current weather at a location.

    Individual fields are nullable because providers differ in what they return
    (e.g. UV often needs a separate endpoint that may be unavailable on the free
    tier). `condition` is the human-readable sky description (e.g. "多云").
    `location` echoes the queried coordinates, `observed_at` is the provider's
    observation timestamp when given.
    """

    temp_c: float | None = None
    humidity_pct: int | None = None
    uv_index: float | None = None
    precip_mm: float | None = None
    condition: str | None = None
    observed_at: str | None = None
    location: str | None = None


class WeatherProvider(Protocol):
    """Anything that can turn a location into a `WeatherSnapshot`.

    `configured` lets callers (and tests) check credentials without making a
    call. `get_now` raises `WeatherNotConfiguredError` when unconfigured and
    `WeatherError` on any provider/transport failure.
    """

    @property
    def configured(self) -> bool: ...

    def get_now(self, lat: float, lon: float) -> Awaitable[WeatherSnapshot]: ...


__all__ = [
    "WeatherError",
    "WeatherNotConfiguredError",
    "WeatherSnapshot",
    "WeatherProvider",
]
