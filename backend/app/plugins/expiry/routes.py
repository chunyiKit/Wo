"""Expiry (到期管家) plugin routes — list / create / update / delete.

URL space: `/families/{family_id}/plugins/expiry/...` (mounted under `/api/v1`).
Every route enforces family membership.
"""

from uuid import UUID

from fastapi import APIRouter
from sqlmodel import select

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.plugins.expiry.models import (
    ExpiryItem,
    ExpiryItemCreate,
    ExpiryItemRead,
    ExpiryItemUpdate,
)
from app.plugins.expiry.service import build_read

router = APIRouter(
    prefix="/families/{family_id}/plugins/expiry",
    tags=["expiry"],
)


async def _load(session: SessionDep, family_id: UUID, item_id: UUID) -> ExpiryItem:
    row = await session.get(ExpiryItem, item_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "记录不存在", status_code=404)
    return row


def _validate_name(name: str) -> str:
    name = name.strip()
    if not name:
        raise AppError(ErrorCode.VALIDATION_ERROR, "名称不能为空", status_code=400)
    return name


@router.get("/items", response_model=ApiResponse[list[ExpiryItemRead]])
async def list_items(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    active: bool | None = None,
) -> ApiResponse[list[ExpiryItemRead]]:
    """List the family's expiry items. `?active=true/false` to filter; omit for
    all. Ordered active-first, then by soonest expiry date."""
    await require_membership(session, current_user.id, family_id)
    stmt = select(ExpiryItem).where(ExpiryItem.family_id == family_id)
    if active is not None:
        stmt = stmt.where(ExpiryItem.active.is_(active))
    stmt = stmt.order_by(ExpiryItem.active.desc(), ExpiryItem.expire_on)
    rows = (await session.execute(stmt)).scalars().all()
    return ok([build_read(r) for r in rows])


@router.post("/items", response_model=ApiResponse[ExpiryItemRead], status_code=201)
async def create_item(
    family_id: UUID,
    payload: ExpiryItemCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[ExpiryItemRead]:
    await require_membership(session, current_user.id, family_id)
    name = _validate_name(payload.name)
    row = ExpiryItem(
        **payload.model_dump(),
        family_id=family_id,
        created_by=current_user.id,
    )
    row.name = name
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(build_read(row))


@router.put("/items/{item_id}", response_model=ApiResponse[ExpiryItemRead])
async def update_item(
    family_id: UUID,
    item_id: UUID,
    payload: ExpiryItemUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[ExpiryItemRead]:
    await require_membership(session, current_user.id, family_id)
    row = await _load(session, family_id, item_id)
    updates = payload.model_dump(exclude_unset=True)
    if "name" in updates and updates["name"] is not None:
        updates["name"] = _validate_name(updates["name"])
    # Changing the expiry date (or re-activating) re-arms both reminder stages.
    if "expire_on" in updates and updates["expire_on"] is not None:
        row.last_pre_notified_on = None
        row.last_expired_notified_on = None
    for key, value in updates.items():
        setattr(row, key, value)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(build_read(row))


@router.delete("/items/{item_id}", response_model=ApiResponse[dict])
async def delete_item(
    family_id: UUID,
    item_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    row = await _load(session, family_id, item_id)
    await session.delete(row)
    await session.commit()
    return ok({"deleted": str(item_id)})
