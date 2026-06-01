"""AI module entry point — provider selection + convenience callers.

Plugins use this module, not a vendor client directly:

    from app.services.ai import ai_complete, ai_complete_text, AiMessage

    result = await ai_complete_text(
        system="你是记账助手，只输出分类名。",
        user="星巴克拿铁 35 元",
    )
    print(result.content)

Swapping providers is a config change (`ai_provider`), not a code change in the
calling plugin.
"""

from __future__ import annotations

from app.core.config import Settings, settings
from app.services.ai.kimi import KimiClient
from app.services.ai.types import AiError, AiMessage, AiProvider, AiResult


def get_ai_provider(cfg: Settings | None = None) -> AiProvider:
    """Build the configured provider. `cfg` is injectable for tests; defaults to
    the process settings singleton."""
    cfg = cfg or settings
    provider = cfg.ai_provider.lower()
    if provider == "kimi":
        return KimiClient.from_settings(cfg)
    raise AiError(f"不支持的 AI provider: {cfg.ai_provider!r}")


async def ai_complete(
    messages: list[AiMessage],
    *,
    temperature: float | None = None,
    max_tokens: int | None = None,
    provider: AiProvider | None = None,
) -> AiResult:
    """Run a multi-turn completion through the configured provider.

    Pass `provider` to override (e.g. an already-built client); otherwise the
    one selected by settings is used. `temperature` defaults to None (the
    provider's own default) — some models reject explicit values. Raises
    `AiNotConfiguredError` when the provider has no key, `AiError` on failure.
    """
    prov = provider or get_ai_provider()
    if max_tokens is None and settings.ai_default_max_tokens is not None:
        max_tokens = settings.ai_default_max_tokens
    return await prov.complete(
        messages, temperature=temperature, max_tokens=max_tokens
    )


async def ai_complete_text(
    *,
    user: str,
    system: str | None = None,
    temperature: float | None = None,
    max_tokens: int | None = None,
    provider: AiProvider | None = None,
) -> AiResult:
    """Convenience for the common single-prompt case: an optional system
    instruction plus one user message."""
    messages: list[AiMessage] = []
    if system:
        messages.append(AiMessage(role="system", content=system))
    messages.append(AiMessage(role="user", content=user))
    return await ai_complete(
        messages,
        temperature=temperature,
        max_tokens=max_tokens,
        provider=provider,
    )


async def ai_complete_vision(
    *,
    user: str,
    image_data: bytes,
    content_type: str = "image/jpeg",
    system: str | None = None,
    temperature: float | None = None,
    max_tokens: int | None = None,
    provider: AiProvider | None = None,
) -> AiResult:
    """Convenience for the common single-photo case: an optional system
    instruction plus one user message carrying a text prompt and one inline
    image. Requires a vision-capable model (see `config.kimi_model`)."""
    messages: list[AiMessage] = []
    if system:
        messages.append(AiMessage(role="system", content=system))
    messages.append(
        AiMessage.with_image(text=user, image_data=image_data, content_type=content_type)
    )
    return await ai_complete(
        messages,
        temperature=temperature,
        max_tokens=max_tokens,
        provider=provider,
    )


__all__ = [
    "get_ai_provider",
    "ai_complete",
    "ai_complete_text",
    "ai_complete_vision",
]
