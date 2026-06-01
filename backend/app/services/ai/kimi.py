"""Kimi (Moonshot) provider — OpenAI-compatible chat-completions client.

Mirrors the shape of `app.services.push.JPushClient`: a frozen dataclass built
`from_settings`, a `configured` guard, and a single httpx call wrapped so any
transport failure surfaces as the module's domain error (`AiError`).

The request/response shaping is split into pure functions (`build_payload`,
`parse_response`) so they're unit-testable without a network.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

import httpx

from app.services.ai.types import (
    AiError,
    AiMessage,
    AiNotConfiguredError,
    AiResult,
    AiUsage,
)

if TYPE_CHECKING:
    from app.core.config import Settings

logger = logging.getLogger(__name__)


def build_payload(
    *,
    model: str,
    messages: list[AiMessage],
    temperature: float | None,
    max_tokens: int | None,
) -> dict[str, Any]:
    """Shape an OpenAI-style chat-completions body. Pure function.

    `temperature` is omitted when None — some models (e.g. the K2 thinking
    series) fix it to 1 and reject any other value, so the safe default is to
    not send it and let the provider use its own default.
    """
    payload: dict[str, Any] = {
        "model": model,
        "messages": [m.to_dict() for m in messages],
    }
    if temperature is not None:
        payload["temperature"] = temperature
    if max_tokens is not None:
        payload["max_tokens"] = max_tokens
    return payload


def parse_response(body: dict[str, Any], *, fallback_model: str) -> AiResult:
    """Extract an `AiResult` from a chat-completions response body.

    Raises `AiError` if the body lacks a usable assistant message.
    """
    choices = body.get("choices")
    if not choices:
        raise AiError("AI 返回内容为空")
    message = choices[0].get("message") or {}
    content = message.get("content")
    if not isinstance(content, str):
        raise AiError("AI 返回内容格式异常")
    # Thinking models (K2 series) put their reasoning here, separate from the
    # final answer. Optional — absent on non-thinking models.
    reasoning = message.get("reasoning_content")
    reasoning_content = reasoning if isinstance(reasoning, str) and reasoning else None

    usage_raw = body.get("usage")
    usage = None
    if isinstance(usage_raw, dict):
        usage = AiUsage(
            prompt_tokens=int(usage_raw.get("prompt_tokens", 0)),
            completion_tokens=int(usage_raw.get("completion_tokens", 0)),
            total_tokens=int(usage_raw.get("total_tokens", 0)),
        )

    return AiResult(
        content=content,
        model=str(body.get("model") or fallback_model),
        finish_reason=choices[0].get("finish_reason"),
        usage=usage,
        reasoning_content=reasoning_content,
    )


@dataclass(frozen=True)
class KimiClient:
    api_key: str
    base_url: str
    model: str
    timeout_seconds: float
    # Injectable for tests (httpx.MockTransport). None → real network transport.
    transport: httpx.AsyncBaseTransport | None = None

    @classmethod
    def from_settings(cls, settings: Settings) -> KimiClient:
        return cls(
            api_key=settings.kimi_api_key,
            # Tolerate a trailing slash in the configured base URL.
            base_url=settings.kimi_base_url.rstrip("/"),
            model=settings.kimi_model,
            timeout_seconds=settings.ai_timeout_seconds,
        )

    @property
    def configured(self) -> bool:
        return bool(self.api_key)

    async def complete(
        self,
        messages: list[AiMessage],
        *,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> AiResult:
        if not self.configured:
            raise AiNotConfiguredError("Kimi 未配置 API Key")
        if not messages:
            raise AiError("messages 不能为空")

        payload = build_payload(
            model=self.model,
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
        )
        url = f"{self.base_url}/chat/completions"
        headers = {"Authorization": f"Bearer {self.api_key}"}
        try:
            async with httpx.AsyncClient(
                timeout=self.timeout_seconds, transport=self.transport
            ) as http:
                resp = await http.post(url, json=payload, headers=headers)
        except httpx.HTTPError as exc:
            raise AiError(f"Kimi 请求失败: {exc}") from exc

        if resp.status_code != 200:
            # Don't echo the request (it carries the prompt); the provider's
            # error text is enough to diagnose. Never logs the API key.
            raise AiError(f"Kimi 返回错误: {resp.status_code} {resp.text}")

        try:
            body = resp.json()
        except ValueError as exc:
            raise AiError("Kimi 返回非 JSON 内容") from exc
        return parse_response(body, fallback_model=self.model)


__all__ = ["KimiClient", "build_payload", "parse_response"]
