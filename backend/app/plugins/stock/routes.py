"""Stock (囤货铺) routes — CRUD for stock items + shopping list, plus the two
linkage actions that close the loop between them.

URL space: `/families/{family_id}/plugins/stock/...`. Every route enforces
membership via `require_membership`.
"""

from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter
from sqlmodel import select

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.plugins.stock.models import (
    BuyItem,
    BuyItemCreate,
    BuyItemRead,
    BuyItemUpdate,
    MarkBoughtBody,
    StockItem,
    StockItemCreate,
    StockItemRead,
    StockItemUpdate,
)
from app.plugins.stock.service import build_buy_read, build_stock_read

router = APIRouter(
    prefix="/families/{family_id}/plugins/stock",
    tags=["stock"],
)


async def _load_stock(session: SessionDep, family_id: UUID, item_id: UUID) -> StockItem:
    row = await session.get(StockItem, item_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "囤货项不存在", status_code=404)
    return row


async def _load_buy(session: SessionDep, family_id: UUID, buy_id: UUID) -> BuyItem:
    row = await session.get(BuyItem, buy_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "采买项不存在", status_code=404)
    return row


# ── 囤货库存 ──────────────────────────────────────────────────────────


@router.get("/items", response_model=ApiResponse[list[StockItemRead]])
async def list_items(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    low: bool | None = None,
) -> ApiResponse[list[StockItemRead]]:
    """List stock items. `?low=true` for only the ones running low. Low items
    first, then by recency."""
    await require_membership(session, current_user.id, family_id)
    stmt = select(StockItem).where(StockItem.family_id == family_id)
    if low:
        stmt = stmt.where(StockItem.low_at.is_not(None), StockItem.qty <= StockItem.low_at)
    stmt = stmt.order_by(StockItem.created_at.desc())
    rows = (await session.execute(stmt)).scalars().all()
    return ok([build_stock_read(r) for r in rows])


@router.post("/items", response_model=ApiResponse[StockItemRead], status_code=201)
async def create_item(
    family_id: UUID,
    payload: StockItemCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[StockItemRead]:
    await require_membership(session, current_user.id, family_id)
    name = payload.name.strip()
    if not name:
        raise AppError(ErrorCode.VALIDATION_ERROR, "名称不能为空", status_code=400)
    row = StockItem(**payload.model_dump(), family_id=family_id, created_by=current_user.id)
    row.name = name
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(build_stock_read(row))


@router.put("/items/{item_id}", response_model=ApiResponse[StockItemRead])
async def update_item(
    family_id: UUID,
    item_id: UUID,
    payload: StockItemUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[StockItemRead]:
    await require_membership(session, current_user.id, family_id)
    row = await _load_stock(session, family_id, item_id)
    updates = payload.model_dump(exclude_unset=True)
    if "name" in updates and updates["name"] is not None:
        name = updates["name"].strip()
        if not name:
            raise AppError(ErrorCode.VALIDATION_ERROR, "名称不能为空", status_code=400)
        updates["name"] = name
    for key, value in updates.items():
        setattr(row, key, value)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(build_stock_read(row))


@router.delete("/items/{item_id}", response_model=ApiResponse[dict])
async def delete_item(
    family_id: UUID,
    item_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    row = await _load_stock(session, family_id, item_id)
    await session.delete(row)
    await session.commit()
    return ok({"deleted": str(item_id)})


@router.post("/items/{item_id}/to-buy", response_model=ApiResponse[BuyItemRead], status_code=201)
async def add_to_buy(
    family_id: UUID,
    item_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[BuyItemRead]:
    """Raise a shopping-list line for a stock item, linked back to it. If an
    unbought line for this item already exists, return that one instead of
    piling up duplicates."""
    await require_membership(session, current_user.id, family_id)
    item = await _load_stock(session, family_id, item_id)
    existing = (
        await session.execute(
            select(BuyItem).where(
                BuyItem.family_id == family_id,
                BuyItem.stock_item_id == item_id,
                BuyItem.bought.is_(False),
            )
        )
    ).scalars().first()
    if existing is not None:
        return ok(build_buy_read(existing))
    buy = BuyItem(
        family_id=family_id,
        name=item.name,
        emoji=item.emoji,
        want_qty=item.unit,
        stock_item_id=item.id,
        created_by=current_user.id,
    )
    session.add(buy)
    await session.commit()
    await session.refresh(buy)
    return ok(build_buy_read(buy))


# ── 采买待买清单 ──────────────────────────────────────────────────────


@router.get("/buys", response_model=ApiResponse[list[BuyItemRead]])
async def list_buys(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    bought: bool | None = None,
) -> ApiResponse[list[BuyItemRead]]:
    """List shopping-list lines. `?bought=false` for the to-buy ones,
    `?bought=true` for finished. Unbought first, then by recency."""
    await require_membership(session, current_user.id, family_id)
    stmt = select(BuyItem).where(BuyItem.family_id == family_id)
    if bought is not None:
        stmt = stmt.where(BuyItem.bought.is_(bought))
    stmt = stmt.order_by(BuyItem.bought, BuyItem.created_at.desc())
    rows = (await session.execute(stmt)).scalars().all()
    return ok([build_buy_read(r) for r in rows])


@router.post("/buys", response_model=ApiResponse[BuyItemRead], status_code=201)
async def create_buy(
    family_id: UUID,
    payload: BuyItemCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[BuyItemRead]:
    await require_membership(session, current_user.id, family_id)
    name = payload.name.strip()
    if not name:
        raise AppError(ErrorCode.VALIDATION_ERROR, "名称不能为空", status_code=400)
    row = BuyItem(**payload.model_dump(), family_id=family_id, created_by=current_user.id)
    row.name = name
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(build_buy_read(row))


@router.put("/buys/{buy_id}", response_model=ApiResponse[BuyItemRead])
async def update_buy(
    family_id: UUID,
    buy_id: UUID,
    payload: BuyItemUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[BuyItemRead]:
    await require_membership(session, current_user.id, family_id)
    row = await _load_buy(session, family_id, buy_id)
    updates = payload.model_dump(exclude_unset=True)
    if "name" in updates and updates["name"] is not None:
        name = updates["name"].strip()
        if not name:
            raise AppError(ErrorCode.VALIDATION_ERROR, "名称不能为空", status_code=400)
        updates["name"] = name
    if "bought" in updates and updates["bought"] is not None:
        updates["bought_at"] = datetime.now(UTC) if updates["bought"] else None
    for key, value in updates.items():
        setattr(row, key, value)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(build_buy_read(row))


@router.delete("/buys/{buy_id}", response_model=ApiResponse[dict])
async def delete_buy(
    family_id: UUID,
    buy_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    row = await _load_buy(session, family_id, buy_id)
    await session.delete(row)
    await session.commit()
    return ok({"deleted": str(buy_id)})


@router.post("/buys/{buy_id}/bought", response_model=ApiResponse[BuyItemRead])
async def mark_bought(
    family_id: UUID,
    buy_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    body: MarkBoughtBody | None = None,
) -> ApiResponse[BuyItemRead]:
    """Mark a shopping line bought. When `into_stock_qty` is given the units
    flow into stock — bumping the linked stock item, or creating a fresh one
    from this line when there's no link. Idempotent on the bought flag, but the
    restock is applied every call, so send `into_stock_qty` only once."""
    await require_membership(session, current_user.id, family_id)
    row = await _load_buy(session, family_id, buy_id)
    if not row.bought:
        row.bought = True
        row.bought_at = datetime.now(UTC)
        session.add(row)

    qty = body.into_stock_qty if body else None
    if qty:
        if row.stock_item_id is not None:
            target = await session.get(StockItem, row.stock_item_id)
            if target is not None and target.family_id == family_id:
                target.qty += qty
                session.add(target)
        else:
            target = StockItem(
                family_id=family_id,
                name=row.name,
                emoji=row.emoji,
                qty=qty,
                created_by=current_user.id,
            )
            session.add(target)
            await session.flush()
            row.stock_item_id = target.id
            session.add(row)

    await session.commit()
    await session.refresh(row)
    return ok(build_buy_read(row))


@router.post("/buys/{buy_id}/reopen", response_model=ApiResponse[BuyItemRead])
async def reopen_buy(
    family_id: UUID,
    buy_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[BuyItemRead]:
    """Move a bought line back onto the to-buy list (idempotent). Does not undo
    any stock that was already restocked."""
    await require_membership(session, current_user.id, family_id)
    row = await _load_buy(session, family_id, buy_id)
    if row.bought:
        row.bought = False
        row.bought_at = None
        session.add(row)
        await session.commit()
        await session.refresh(row)
    return ok(build_buy_read(row))
