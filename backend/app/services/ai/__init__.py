"""Shared AI module — a provider-agnostic way for plugins to call an LLM.

Public surface (import from here, not the submodules):

    from app.services.ai import (
        ai_complete, ai_complete_text,   # call the model
        AiMessage, AiResult, AiUsage,    # data types
        AiError, AiNotConfiguredError,   # failures to catch
        get_ai_provider,                 # the configured provider, if needed
    )

Currently backed by Kimi (Moonshot); selecting another provider is a config
change (`ai_provider`), invisible to callers.
"""

from app.services.ai.service import (
    ai_complete,
    ai_complete_text,
    ai_complete_vision,
    get_ai_provider,
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
    "get_ai_provider",
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
