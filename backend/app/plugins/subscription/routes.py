"""Subscription (订阅管家) plugin routes — list / create / update / delete.

URL space: `/families/{family_id}/plugins/subscription/...` (mounted under
`/api/v1`). Every route enforces family membership.
"""

from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter
from sqlmodel import select

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.plugins.subscription.models import (
    Subscription,
    SubscriptionCreate,
    SubscriptionRead,
    SubscriptionUpdate,
)
from app.plugins.subscription.service import build_read

router = APIRouter(
    prefix="/families/{family_id}/plugins/subscription",
    tags=["subscription"],
)


async def _load(session: SessionDep, family_id: UUID, sub_id: UUID) -> Subscription:
    row = await session.get(Subscription, sub_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "订阅不存在", status_code=404)
    return row


def _validate(name: str, amount: Decimal) -> str:
    name = name.strip()
    if not name:
        raise AppError(ErrorCode.VALIDATION_ERROR, "名称不能为空", status_code=400)
    if amount <= 0:
        raise AppError(ErrorCode.VALIDATION_ERROR, "金额必须大于 0", status_code=400)
    return name


@router.get("/subscriptions", response_model=ApiResponse[list[SubscriptionRead]])
async def list_subscriptions(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    active: bool | None = None,
) -> ApiResponse[list[SubscriptionRead]]:
    """List the family's subscriptions. `?active=true/false` to filter; omit for
    all. Ordered active-first, then by soonest due date."""
    await require_membership(session, current_user.id, family_id)
    stmt = select(Subscription).where(Subscription.family_id == family_id)
    if active is not None:
        stmt = stmt.where(Subscription.active.is_(active))
    stmt = stmt.order_by(Subscription.active.desc(), Subscription.next_due)
    rows = (await session.execute(stmt)).scalars().all()
    return ok([build_read(r) for r in rows])


@router.post(
    "/subscriptions", response_model=ApiResponse[SubscriptionRead], status_code=201
)
async def create_subscription(
    family_id: UUID,
    payload: SubscriptionCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[SubscriptionRead]:
    await require_membership(session, current_user.id, family_id)
    name = _validate(payload.name, payload.amount)
    row = Subscription(
        **payload.model_dump(),
        family_id=family_id,
        created_by=current_user.id,
    )
    row.name = name
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(build_read(row))


@router.put(
    "/subscriptions/{sub_id}", response_model=ApiResponse[SubscriptionRead]
)
async def update_subscription(
    family_id: UUID,
    sub_id: UUID,
    payload: SubscriptionUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[SubscriptionRead]:
    await require_membership(session, current_user.id, family_id)
    row = await _load(session, family_id, sub_id)
    updates = payload.model_dump(exclude_unset=True)
    if "name" in updates and updates["name"] is not None:
        updates["name"] = _validate(updates["name"], row.amount)
    if "amount" in updates and updates["amount"] is not None and updates["amount"] <= 0:
        raise AppError(ErrorCode.VALIDATION_ERROR, "金额必须大于 0", status_code=400)
    # Editing the due date (or re-activating) should let reminders fire again.
    if "next_due" in updates and updates["next_due"] is not None:
        row.last_notified_due = None
    for key, value in updates.items():
        setattr(row, key, value)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(build_read(row))


@router.delete("/subscriptions/{sub_id}", response_model=ApiResponse[dict])
async def delete_subscription(
    family_id: UUID,
    sub_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    row = await _load(session, family_id, sub_id)
    await session.delete(row)
    await session.commit()
    return ok({"deleted": str(sub_id)})
