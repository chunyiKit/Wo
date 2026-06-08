"""Per-family AI model configuration service.

The single source of truth for "which model + key does family F use for AI type
T". Plugins go through `resolve_model` (indirectly, via app.services.ai); the
settings UI goes through `list_models` / `upsert_model` / `delete_model`.

API keys are encrypted at rest (app.core.crypto). The old global static config
(settings.kimi_*) is migrated lazily per family by `ensure_seeded`.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.config import settings
from app.core.crypto import decrypt_secret, encrypt_secret
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_admin, require_membership
from app.models.ai_model import FamilyAiModel
from app.models.user import User

# Capability types a plugin can request. multimodal/text are chat models we call
# today; image/video are configurable placeholders for future generation plugins.
AI_TYPES: tuple[str, ...] = ("multimodal", "text", "image", "video")
CALLABLE_TYPES: frozenset[str] = frozenset({"multimodal", "text"})

# Human labels for error messages.
TYPE_LABELS: dict[str, str] = {
    "multimodal": "多模态",
    "text": "文本",
    "image": "图片生成",
    "video": "视频生成",
}


@dataclass(frozen=True)
class ResolvedModel:
    """A family's decrypted, ready-to-call model config for one type."""

    label: str
    base_url: str
    model: str
    api_key: str


def _validate_type(ai_type: str) -> None:
    if ai_type not in AI_TYPES:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            f"未知的 AI 类型: {ai_type}",
            status_code=400,
            details={"allowed": list(AI_TYPES)},
        )


async def _get_row(
    session: AsyncSession, family_id: UUID, ai_type: str
) -> FamilyAiModel | None:
    stmt = select(FamilyAiModel).where(
        FamilyAiModel.family_id == family_id,
        FamilyAiModel.ai_type == ai_type,
    )
    return (await session.execute(stmt)).scalar_one_or_none()


async def ensure_seeded(session: AsyncSession, family_id: UUID) -> None:
    """One-time migration: if this family has no multimodal model yet and the
    deprecated env Kimi config is present, seed a multimodal row from it
    (encrypted). No-op once a row exists or env is blank."""
    if not settings.kimi_api_key:
        return
    if await _get_row(session, family_id, "multimodal") is not None:
        return
    row = FamilyAiModel(
        family_id=family_id,
        ai_type="multimodal",
        label="Kimi",
        base_url=settings.kimi_base_url,
        model=settings.kimi_model,
        api_key_encrypted=encrypt_secret(settings.kimi_api_key),
        key_hint=settings.kimi_api_key[-4:],
        enabled=True,
        updated_by=None,
    )
    session.add(row)
    await session.commit()


async def resolve_model(
    session: AsyncSession, family_id: UUID, ai_type: str
) -> ResolvedModel | None:
    """The enabled model config for (family, type), decrypted — or None when the
    family hasn't configured (or has disabled) one."""
    _validate_type(ai_type)
    if ai_type == "multimodal":
        await ensure_seeded(session, family_id)
    row = await _get_row(session, family_id, ai_type)
    if row is None or not row.enabled:
        return None
    return ResolvedModel(
        label=row.label,
        base_url=row.base_url,
        model=row.model,
        api_key=decrypt_secret(row.api_key_encrypted),
    )


async def list_models(
    session: AsyncSession, family_id: UUID
) -> dict[str, FamilyAiModel]:
    """All configured rows for a family, keyed by ai_type (migrates first)."""
    await ensure_seeded(session, family_id)
    stmt = select(FamilyAiModel).where(FamilyAiModel.family_id == family_id)
    rows = (await session.execute(stmt)).scalars().all()
    return {row.ai_type: row for row in rows}


async def upsert_model(
    session: AsyncSession,
    *,
    family_id: UUID,
    ai_type: str,
    actor: User,
    label: str,
    base_url: str,
    model: str,
    api_key: str | None,
    enabled: bool = True,
) -> FamilyAiModel:
    """Create or update a family's model for one type (admin only).

    `api_key=None` keeps the existing key (so the client needn't resend it on an
    edit); a non-empty string replaces it. Creating a row requires a key.
    """
    membership = await require_membership(session, actor.id, family_id)
    require_admin(membership)
    _validate_type(ai_type)

    label = label.strip()
    base_url = base_url.strip()
    model = model.strip()
    if not label or not base_url or not model:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            "名称 / 接口地址 / 模型 都不能为空",
            status_code=400,
        )

    encrypted: str | None = None
    hint: str | None = None
    if api_key:
        encrypted = encrypt_secret(api_key)
        hint = api_key[-4:]

    row = await _get_row(session, family_id, ai_type)
    if row is None:
        if encrypted is None:
            raise AppError(
                ErrorCode.VALIDATION_ERROR,
                "首次配置必须填写 API Key",
                status_code=400,
            )
        row = FamilyAiModel(
            family_id=family_id,
            ai_type=ai_type,
            label=label,
            base_url=base_url,
            model=model,
            api_key_encrypted=encrypted,
            key_hint=hint or "",
            enabled=enabled,
            updated_by=actor.id,
        )
    else:
        row.label = label
        row.base_url = base_url
        row.model = model
        row.enabled = enabled
        row.updated_by = actor.id
        if encrypted is not None:  # keep existing key when not resent
            row.api_key_encrypted = encrypted
            row.key_hint = hint or ""

    row.updated_at = datetime.now(UTC)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return row


async def delete_model(
    session: AsyncSession,
    *,
    family_id: UUID,
    ai_type: str,
    actor: User,
) -> None:
    """Remove a family's model for one type (admin only). No-op if absent."""
    membership = await require_membership(session, actor.id, family_id)
    require_admin(membership)
    _validate_type(ai_type)
    row = await _get_row(session, family_id, ai_type)
    if row is not None:
        await session.delete(row)
        await session.commit()


__all__ = [
    "AI_TYPES",
    "CALLABLE_TYPES",
    "TYPE_LABELS",
    "ResolvedModel",
    "ensure_seeded",
    "resolve_model",
    "list_models",
    "upsert_model",
    "delete_model",
]
