"""AI module entry point — resolve a family's model by capability type, then call.

Plugins use this module, not a vendor client directly. They request a *type*
(multimodal / text / …) for a family; the family's configured model + key (see
app.services.ai_config) is loaded and called:

    from app.services.ai import ai_complete_vision

    result = await ai_complete_vision(
        session=session, family_id=family_id,
        system="你是记账助手", user="识别这张小票", image_data=photo,
    )

When the family has no model configured for that type, `AiNotConfiguredError` is
raised with an actionable message pointing at 我的 → 设置 → AI 集成设置.

Tests (and any caller holding a pre-built client) may pass `provider=` to skip
resolution entirely — then `session`/`family_id` are not needed.
"""

from __future__ import annotations

from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.services.ai.client import OpenAICompatibleClient
from app.services.ai.image_client import ImageGenerationClient
from app.services.ai.types import (
    AiMessage,
    AiNotConfiguredError,
    AiProvider,
    AiResult,
)


async def _resolve_provider(
    *,
    session: AsyncSession | None,
    family_id: UUID | None,
    ai_type: str,
) -> AiProvider:
    """Build the family's provider for `ai_type`, or raise an actionable error."""
    # Imported lazily to avoid a config→models import cycle at module load.
    from app.services.ai_config import TYPE_LABELS, resolve_model

    if session is None or family_id is None:
        raise AiNotConfiguredError("缺少家庭上下文，无法选择 AI 模型")
    resolved = await resolve_model(session, family_id, ai_type)
    if resolved is None:
        label = TYPE_LABELS.get(ai_type, ai_type)
        raise AiNotConfiguredError(
            f"当前家庭未配置「{label}」AI 模型，请到 我的 → 设置 → AI 集成设置 中配置"
        )
    return OpenAICompatibleClient(
        api_key=resolved.api_key,
        base_url=resolved.base_url,
        model=resolved.model,
        timeout_seconds=settings.ai_timeout_seconds,
    )


async def ai_complete(
    messages: list[AiMessage],
    *,
    session: AsyncSession | None = None,
    family_id: UUID | None = None,
    ai_type: str = "text",
    temperature: float | None = None,
    max_tokens: int | None = None,
    provider: AiProvider | None = None,
) -> AiResult:
    """Run a multi-turn completion through the family's model for `ai_type`.

    Pass `provider` to use an already-built client (skips resolution; no
    session/family needed). `temperature` defaults to None (the provider's own
    default). Raises `AiNotConfiguredError` when no model is configured for the
    type, `AiError` on a provider/transport failure.
    """
    prov = provider or await _resolve_provider(
        session=session, family_id=family_id, ai_type=ai_type
    )
    if max_tokens is None and settings.ai_default_max_tokens is not None:
        max_tokens = settings.ai_default_max_tokens
    return await prov.complete(
        messages, temperature=temperature, max_tokens=max_tokens
    )


async def ai_complete_text(
    *,
    user: str,
    system: str | None = None,
    session: AsyncSession | None = None,
    family_id: UUID | None = None,
    ai_type: str = "text",
    temperature: float | None = None,
    max_tokens: int | None = None,
    provider: AiProvider | None = None,
) -> AiResult:
    """Convenience for the common single-prompt case: an optional system
    instruction plus one user message. Defaults to the family's `text` model."""
    messages: list[AiMessage] = []
    if system:
        messages.append(AiMessage(role="system", content=system))
    messages.append(AiMessage(role="user", content=user))
    return await ai_complete(
        messages,
        session=session,
        family_id=family_id,
        ai_type=ai_type,
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
    session: AsyncSession | None = None,
    family_id: UUID | None = None,
    ai_type: str = "multimodal",
    temperature: float | None = None,
    max_tokens: int | None = None,
    provider: AiProvider | None = None,
) -> AiResult:
    """Convenience for the common single-photo case: an optional system
    instruction plus one user message carrying a text prompt and one inline
    image. Defaults to the family's `multimodal` model (vision-capable)."""
    messages: list[AiMessage] = []
    if system:
        messages.append(AiMessage(role="system", content=system))
    messages.append(
        AiMessage.with_image(text=user, image_data=image_data, content_type=content_type)
    )
    return await ai_complete(
        messages,
        session=session,
        family_id=family_id,
        ai_type=ai_type,
        temperature=temperature,
        max_tokens=max_tokens,
        provider=provider,
    )


async def ai_generate_image(
    *,
    prompt: str,
    session: AsyncSession | None = None,
    family_id: UUID | None = None,
    image_data: bytes | None = None,
    content_type: str = "image/jpeg",
    size: str = "2048x2048",
    client: ImageGenerationClient | None = None,
) -> tuple[bytes, str]:
    """Generate (or restyle) an image via the family's configured `image` model.

    `image_data` present → img2img (restyle the source). Returns (bytes,
    content_type). Pass `client` to use a pre-built one (tests). Raises
    `AiNotConfiguredError` when no image model is configured.
    """
    if client is None:
        # Lazy import avoids a config→models import cycle at module load.
        from app.services.ai_config import resolve_model

        if session is None or family_id is None:
            raise AiNotConfiguredError("缺少家庭上下文，无法选择图片生成模型")
        resolved = await resolve_model(session, family_id, "image")
        if resolved is None:
            raise AiNotConfiguredError(
                "当前家庭未配置「图片生成」AI 模型，请到 我的 → 设置 → AI 集成设置 中配置"
            )
        client = ImageGenerationClient(
            api_key=resolved.api_key,
            base_url=resolved.base_url,
            model=resolved.model,
            timeout_seconds=settings.ai_timeout_seconds,
        )
    return await client.generate(
        prompt, image_data=image_data, content_type=content_type, size=size
    )


__all__ = [
    "ai_complete",
    "ai_complete_text",
    "ai_complete_vision",
    "ai_generate_image",
]
