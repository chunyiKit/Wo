"""JPush (极光推送) client + the push-message contract.

`PushMessage` is the provider-agnostic payload the dispatcher hands to a sender;
`PushSender` is the structural type a sender satisfies. `JPushClient` is the
concrete极光 implementation.

The client is intentionally a *no-op when unconfigured* (no app_key/master_secret):
`send_push` logs and returns, which the dispatcher treats as a successful
delivery. This keeps dev and tests running without real credentials or network
while leaving the same code path in place for production.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Protocol

import httpx

if TYPE_CHECKING:
    from app.core.config import Settings

logger = logging.getLogger(__name__)

# JPush rejects most pushes in well under a second; cap so a slow provider can't
# stall a dispatch pass indefinitely.
DEFAULT_TIMEOUT_SECONDS = 10.0


class PushError(Exception):
    """Raised when the provider rejects a send. Signals the outbox to retry."""


@dataclass(frozen=True)
class PushMessage:
    """Provider-agnostic push payload. `extras` rides along as a data dict so the
    app can deep-link on tap (deeplink / notification_id / type)."""

    registration_ids: list[str]
    title: str
    body: str
    extras: dict[str, str] = field(default_factory=dict)


class PushSender(Protocol):
    """Anything that can deliver a `PushMessage`. Raises `PushError` on failure."""

    async def __call__(self, message: PushMessage) -> None: ...


def build_jpush_payload(message: PushMessage, *, apns_production: bool) -> dict:
    """Shape a JPush Push API v3 request body. Pure function — unit-testable."""
    extras = dict(message.extras)
    return {
        "platform": "all",
        "audience": {"registration_id": list(message.registration_ids)},
        "notification": {
            "android": {
                "alert": message.body,
                "title": message.title,
                "extras": extras,
            },
            "ios": {
                "alert": {"title": message.title, "body": message.body},
                "sound": "default",
                "extras": extras,
            },
        },
        # apns_production=false routes to Apple's sandbox gateway (dev builds);
        # true is required for TestFlight/App Store builds.
        "options": {"apns_production": apns_production},
    }


@dataclass(frozen=True)
class JPushClient:
    app_key: str
    master_secret: str
    api_url: str
    apns_production: bool
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS

    @classmethod
    def from_settings(cls, settings: Settings) -> JPushClient:
        return cls(
            app_key=settings.jpush_app_key,
            master_secret=settings.jpush_master_secret,
            api_url=settings.jpush_api_url,
            apns_production=settings.jpush_apns_production,
        )

    @property
    def configured(self) -> bool:
        return bool(self.app_key and self.master_secret)

    async def send_push(self, message: PushMessage) -> None:
        if not message.registration_ids:
            return
        if not self.configured:
            logger.warning(
                "JPush not configured — skipping push to %d device(s)",
                len(message.registration_ids),
            )
            return
        payload = build_jpush_payload(message, apns_production=self.apns_production)
        try:
            async with httpx.AsyncClient(timeout=self.timeout_seconds) as http:
                resp = await http.post(
                    self.api_url,
                    json=payload,
                    auth=(self.app_key, self.master_secret),
                )
        except httpx.HTTPError as exc:
            raise PushError(f"JPush request failed: {exc}") from exc
        if resp.status_code != 200:
            raise PushError(f"JPush rejected push: {resp.status_code} {resp.text}")
