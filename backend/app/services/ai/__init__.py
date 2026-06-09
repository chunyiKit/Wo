"""Shared AI module — a provider-agnostic way for plugins to call an LLM.

Public surface (import from here, not the submodules):

    from app.services.ai import (
        ai_complete, ai_complete_text,   # call the model (by family + type)
        AiMessage, AiResult, AiUsage,    # data types
        AiError, AiNotConfiguredError,   # failures to catch
    )

The concrete model + key is resolved per family + capability type from
app.services.ai_config; callers never reference a vendor or a specific model.
"""

from app.services.ai.client import OpenAICompatibleClient
from app.services.ai.image_client import ImageGenerationClient
from app.services.ai.service import (
    ai_complete,
    ai_complete_text,
    ai_complete_vision,
    ai_generate_image,
)
from app.services.ai.types import (
    AiError,
    AiMessage,
    AiNotConfiguredError,
    AiProvider,
    AiResult,
    AiUsage,
    ContentPart,
    ImagePart,
    TextPart,
)

__all__ = [
    "ai_complete",
    "ai_complete_text",
    "ai_complete_vision",
    "ai_generate_image",
    "OpenAICompatibleClient",
    "ImageGenerationClient",
    "AiProvider",
    "AiMessage",
    "AiResult",
    "AiUsage",
    "AiError",
    "AiNotConfiguredError",
    "TextPart",
    "ImagePart",
    "ContentPart",
]
