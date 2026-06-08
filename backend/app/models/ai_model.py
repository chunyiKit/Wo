"""Per-family AI model configuration.

One row per (family, ai_type). `ai_type` is the *capability* a plugin asks for —
multimodal / text / image / video — decoupling plugins from any specific vendor
or model id. The API key is stored encrypted (Fernet, see app.core.crypto); the
plaintext never leaves the server and is never returned to the client.

Replaces the old global static config (settings.kimi_*): models are now chosen
and keyed by each family in-app under 我的 → 设置 → AI 集成设置.
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import Column, DateTime, UniqueConstraint
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7


class FamilyAiModel(SQLModel, table=True):
    """A model service one family configured for one AI capability type."""

    __tablename__ = "family_ai_models"
    __table_args__ = (
        UniqueConstraint("family_id", "ai_type", name="uq_family_ai_type"),
    )

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    # One of app.services.ai_config.AI_TYPES: multimodal | text | image | video.
    ai_type: str = Field(max_length=16)

    label: str = Field(max_length=40)  # display name, e.g. "Kimi K2.6"
    base_url: str = Field(max_length=255)  # OpenAI-compatible /v1 base
    model: str = Field(max_length=80)  # model id sent to the provider
    # Fernet ciphertext of the API key. Never returned to clients in plaintext.
    api_key_encrypted: str = Field()
    # Non-secret last-4 of the key, shown in the UI so the user recognizes which
    # key is set without ever exposing it (and without decrypting on read).
    key_hint: str = Field(default="", max_length=8)

    enabled: bool = Field(default=True)

    updated_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    updated_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )
