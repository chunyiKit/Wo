"""OpenAI-compatible chat-completions client.

Most providers we target (Kimi/Moonshot, DeepSeek, 通义/DashScope-compat, 豆包,
OpenAI itself) speak the same `/chat/completions` dialect, so one client
parameterized by `(api_key, base_url, model)` covers them all. It's built per
call from the requesting family's configured model (see app.services.ai_config),
not from global settings.

`build_payload` / `parse_response` are pure functions split out for unit testing
without a network.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

import httpx

from app.services.ai.types import (
    AiError,
    AiMessage,
    AiNotConfiguredError,
    AiResult,
    AiUsage,
)

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
class OpenAICompatibleClient:
    api_key: str
    base_url: str
    model: str
    timeout_seconds: float
    # Injectable for tests (httpx.MockTransport). None → real network transport.
    transport: httpx.AsyncBaseTransport | None = None

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
            raise AiNotConfiguredError("AI 模型未配置 API Key")
        if not messages:
            raise AiError("messages 不能为空")

        payload = build_payload(
            model=self.model,
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
        )
        url = f"{self.base_url.rstrip('/')}/chat/completions"
        headers = {"Authorization": f"Bearer {self.api_key}"}
        try:
            async with httpx.AsyncClient(
                timeout=self.timeout_seconds, transport=self.transport
            ) as http:
                resp = await http.post(url, json=payload, headers=headers)
        except httpx.HTTPError as exc:
            # str(exc) is often empty for timeouts — include the type so the log
            # distinguishes a timeout (ReadTimeout) from a connect failure, etc.
            detail = str(exc) or type(exc).__name__
            raise AiError(f"AI 请求失败: {detail}") from exc

        if resp.status_code != 200:
            # Don't echo the request (it carries the prompt); the provider's
            # error text is enough to diagnose. Never logs the API key.
            raise AiError(f"AI 返回错误: {resp.status_code} {resp.text}")

        try:
            body = resp.json()
        except ValueError as exc:
            raise AiError("AI 返回非 JSON 内容") from exc
        return parse_response(body, fallback_model=self.model)


__all__ = ["OpenAICompatibleClient", "build_payload", "parse_response"]
