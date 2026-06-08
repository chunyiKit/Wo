"""AI 集成设置 — per-family model configuration endpoints.

Family-scoped under `/families/{family_id}/ai-models`. Read is member-level;
create/update/delete are admin-only (enforced in app.services.ai_config). API
keys are write-only: the plaintext is never returned, only `has_key` + a `hint`
(last 4) so the user recognizes which key is set.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.models.ai_model import FamilyAiModel
from app.services.ai import AiError, AiNotConfiguredError, ai_complete_text
from app.services.ai_config import (
    AI_TYPES,
    CALLABLE_TYPES,
    TYPE_LABELS,
    delete_model,
    list_models,
    upsert_model,
)

router = APIRouter(prefix="/families/{family_id}", tags=["ai"])


class AiModelRead(BaseModel):
    """One AI capability type's config for a family (key never included)."""

    ai_type: str
    type_label: str
    callable: bool  # whether the backend actually calls this type today
    configured: bool
    label: str | None = None
    base_url: str | None = None
    model: str | None = None
    has_key: bool = False
    key_hint: str = ""
    enabled: bool = False
    updated_at: datetime | None = None


class AiModelUpsert(BaseModel):
    label: str = Field(min_length=1, max_length=40)
    base_url: str = Field(min_length=1, max_length=255)
    model: str = Field(min_length=1, max_length=80)
    # Omit / null to keep the existing key on edit; required when first creating.
    api_key: str | None = Field(default=None, max_length=255)
    enabled: bool = True


def _read(ai_type: str, row: FamilyAiModel | None) -> AiModelRead:
    base = AiModelRead(
        ai_type=ai_type,
        type_label=TYPE_LABELS.get(ai_type, ai_type),
        callable=ai_type in CALLABLE_TYPES,
        configured=row is not None,
    )
    if row is None:
        return base
    return base.model_copy(
        update={
            "label": row.label,
            "base_url": row.base_url,
            "model": row.model,
            "has_key": bool(row.api_key_encrypted),
            "key_hint": row.key_hint,
            "enabled": row.enabled,
            "updated_at": row.updated_at,
        }
    )


@router.get("/ai-models", response_model=ApiResponse[list[AiModelRead]])
async def get_ai_models(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[AiModelRead]]:
    """All four capability types with their config (configured or placeholder)."""
    await require_membership(session, current_user.id, family_id)
    rows = await list_models(session, family_id)
    return ok([_read(t, rows.get(t)) for t in AI_TYPES])


@router.put("/ai-models/{ai_type}", response_model=ApiResponse[AiModelRead])
async def put_ai_model(
    family_id: UUID,
    ai_type: str,
    body: AiModelUpsert,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[AiModelRead]:
    """Create or update the family's model for one type (admin only)."""
    row = await upsert_model(
        session,
        family_id=family_id,
        ai_type=ai_type,
        actor=current_user,
        label=body.label,
        base_url=body.base_url,
        model=body.model,
        api_key=body.api_key,
        enabled=body.enabled,
    )
    return ok(_read(ai_type, row))


@router.delete("/ai-models/{ai_type}", response_model=ApiResponse[None])
async def remove_ai_model(
    family_id: UUID,
    ai_type: str,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[None]:
    """Remove the family's model for one type (admin only)."""
    await delete_model(
        session, family_id=family_id, ai_type=ai_type, actor=current_user
    )
    return ok(None)


@router.post("/ai-models/{ai_type}/test", response_model=ApiResponse[None])
async def test_ai_model(
    family_id: UUID,
    ai_type: str,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[None]:
    """Validate the saved config for a type with a tiny live call (member-level).

    Only chat types (multimodal/text) are testable; image/video generation use
    different APIs not wired yet.
    """
    await require_membership(session, current_user.id, family_id)
    if ai_type not in CALLABLE_TYPES:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            f"「{TYPE_LABELS.get(ai_type, ai_type)}」暂不支持连通测试",
            status_code=400,
        )
    try:
        await ai_complete_text(
            session=session,
            family_id=family_id,
            ai_type=ai_type,
            user="ping",
            max_tokens=1,
        )
    except AiNotConfiguredError as exc:
        raise AppError(ErrorCode.VALIDATION_ERROR, str(exc), status_code=400) from exc
    except AiError as exc:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            f"连接失败：{exc}",
            status_code=422,
        ) from exc
    return ok(None)
