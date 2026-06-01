"""Provider-agnostic types for the shared AI module.

`AiMessage` / `AiResult` are the contract any provider speaks; `AiProvider` is
the structural type a concrete client (Kimi, …) satisfies. Plugins depend only
on these, never on a specific vendor's SDK or response shape.
"""

from __future__ import annotations

import base64
from collections.abc import Awaitable
from dataclasses import dataclass
from typing import Any, Literal, Protocol

Role = Literal["system", "user", "assistant"]


class AiError(Exception):
    """A call to the AI provider failed (network, bad status, malformed body)."""


class AiNotConfiguredError(AiError):
    """The selected provider has no credentials. Callers should treat this as a
    feature-disabled signal rather than a transient failure (no point retrying)."""


@dataclass(frozen=True)
class TextPart:
    """A text block inside a multimodal message body."""

    text: str

    def to_dict(self) -> dict[str, Any]:
        return {"type": "text", "text": self.text}


@dataclass(frozen=True)
class ImagePart:
    """An image block inside a multimodal message body.

    `image` is either a public URL the provider can fetch, or — preferred for
    private content the provider can't reach — an inline `data:` URL carrying
    base64 bytes (e.g. `data:image/jpeg;base64,...`). Use `from_bytes` to build
    one from raw image bytes.
    """

    image: str

    @classmethod
    def from_bytes(cls, data: bytes, *, content_type: str = "image/jpeg") -> ImagePart:
        b64 = base64.b64encode(data).decode("ascii")
        return cls(image=f"data:{content_type};base64,{b64}")

    def to_dict(self) -> dict[str, Any]:
        # OpenAI-compatible vision shape (Kimi/Moonshot speaks the same dialect).
        return {"type": "image_url", "image_url": {"url": self.image}}


# One block of a multimodal message body.
ContentPart = TextPart | ImagePart


@dataclass(frozen=True)
class AiMessage:
    """One turn in a chat. `system` sets behavior, `user` is the prompt,
    `assistant` carries prior model output for multi-turn context.

    `content` is either a plain string (text-only — the common case) or a list
    of content parts (text + images) for multimodal requests. Sending image
    parts requires a vision-capable model.
    """

    role: Role
    content: str | list[ContentPart]

    @classmethod
    def with_image(
        cls,
        *,
        text: str,
        image_data: bytes,
        content_type: str = "image/jpeg",
        role: Role = "user",
    ) -> AiMessage:
        """Build a message carrying a text prompt plus one inline image (base64
        `data:` URL). Convenience for the common single-photo case."""
        return cls(
            role=role,
            content=[
                TextPart(text=text),
                ImagePart.from_bytes(image_data, content_type=content_type),
            ],
        )

    def to_dict(self) -> dict[str, Any]:
        # str content is serialized verbatim — byte-identical to the pre-
        # multimodal behavior, so existing text-only callers are unaffected.
        if isinstance(self.content, str):
            return {"role": self.role, "content": self.content}
        return {
            "role": self.role,
            "content": [part.to_dict() for part in self.content],
        }


@dataclass(frozen=True)
class AiUsage:
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int


@dataclass(frozen=True)
class AiResult:
    """What a provider returns. `content` is the assistant's final answer.

    `reasoning_content` carries a thinking model's step-by-step reasoning when
    the provider exposes it (e.g. Kimi K2 thinking series); it's separate from
    the answer and usually ignored by plugins. `finish_reason == "length"` with
    an empty `content` means the token budget was spent before the answer — give
    a larger `max_tokens`. `usage` is the token accounting when reported."""

    content: str
    model: str
    finish_reason: str | None = None
    usage: AiUsage | None = None
    reasoning_content: str | None = None


class AiProvider(Protocol):
    """Anything that can turn a list of messages into an `AiResult`.

    `configured` lets callers (and tests) check credentials without making a
    call. `complete` raises `AiNotConfiguredError` when unconfigured and
    `AiError` on any provider/transport failure.
    """

    @property
    def configured(self) -> bool: ...

    def complete(
        self,
        messages: list[AiMessage],
        *,
        temperature: float = ...,
        max_tokens: int | None = ...,
    ) -> Awaitable[AiResult]: ...


__all__ = [
    "Role",
    "AiError",
    "AiNotConfiguredError",
    "TextPart",
    "ImagePart",
    "ContentPart",
    "AiMessage",
    "AiUsage",
    "AiResult",
    "AiProvider",
]
