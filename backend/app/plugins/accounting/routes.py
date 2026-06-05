"""Accounting plugin routes — expenses + recurring monthly budget.

URL space follows the contract: `/families/{family_id}/plugins/accounting/...`.
Every route enforces membership via `require_membership`.
"""

from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, File, UploadFile
from sqlmodel import select

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.images import validate_image
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.plugins.accounting.models import (
    ALLOWED_CATEGORIES,
    Budget,
    BudgetRead,
    BudgetUpdate,
    SummaryRead,
    Transaction,
    TransactionCreate,
    TransactionRead,
    TransactionUpdate,
)
from app.plugins.accounting.receipt import ReceiptScanResult, scan_receipt
from app.plugins.accounting.service import (
    build_read,
    get_budget,
    month_bounds,
    month_total,
)
from app.services.ai import AiError, AiNotConfiguredError
from app.services.membership import member_info_map as member_map

router = APIRouter(
    prefix="/families/{family_id}/plugins/accounting",
    tags=["accounting"],
)


def _validate_category(category: str) -> None:
    if category not in ALLOWED_CATEGORIES:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            f"未知标签：{category}",
            status_code=422,
            details={"allowed": list(ALLOWED_CATEGORIES)},
        )


@router.get("/transactions", response_model=ApiResponse[list[TransactionRead]])
async def list_transactions(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    year: int | None = None,
    month: int | None = None,
) -> ApiResponse[list[TransactionRead]]:
    await require_membership(session, current_user.id, family_id)
    stmt = select(Transaction).where(Transaction.family_id == family_id)
    if year is not None and month is not None:
        start, end = month_bounds(year, month)
        stmt = stmt.where(
            Transaction.created_at >= start,
            Transaction.created_at < end,
        )
    stmt = stmt.order_by(Transaction.created_at.desc())
    rows = (await session.execute(stmt)).scalars().all()
    members = await member_map(session, family_id)
    return ok([build_read(r, members) for r in rows])


@router.post(
    "/transactions",
    response_model=ApiResponse[TransactionRead],
    status_code=201,
)
async def create_transaction(
    family_id: UUID,
    payload: TransactionCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[TransactionRead]:
    await require_membership(session, current_user.id, family_id)
    _validate_category(payload.category)
    row = Transaction(
        **payload.model_dump(),
        family_id=family_id,
        created_by=current_user.id,
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    members = await member_map(session, family_id)
    return ok(build_read(row, members))


@router.put(
    "/transactions/{transaction_id}",
    response_model=ApiResponse[TransactionRead],
)
async def update_transaction(
    family_id: UUID,
    transaction_id: UUID,
    payload: TransactionUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[TransactionRead]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(Transaction, transaction_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "支出记录不存在", status_code=404)
    updates = payload.model_dump(exclude_unset=True)
    if "category" in updates and updates["category"] is not None:
        _validate_category(updates["category"])
    for key, value in updates.items():
        setattr(row, key, value)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    members = await member_map(session, family_id)
    return ok(build_read(row, members))


@router.delete("/transactions/{transaction_id}", response_model=ApiResponse[dict])
async def delete_transaction(
    family_id: UUID,
    transaction_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(Transaction, transaction_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "支出记录不存在", status_code=404)
    await session.delete(row)
    await session.commit()
    return ok({"deleted": str(transaction_id)})


@router.get("/budget", response_model=ApiResponse[BudgetRead])
async def read_budget(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[BudgetRead]:
    await require_membership(session, current_user.id, family_id)
    amount = await get_budget(session, family_id)
    return ok(BudgetRead(monthly_amount=amount))


@router.put("/budget", response_model=ApiResponse[BudgetRead])
async def set_budget(
    family_id: UUID,
    payload: BudgetUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[BudgetRead]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(Budget, family_id)
    if row is None:
        row = Budget(
            family_id=family_id,
            monthly_amount=payload.monthly_amount,
            updated_by=current_user.id,
        )
    else:
        row.monthly_amount = payload.monthly_amount
        row.updated_by = current_user.id
        row.updated_at = datetime.now(UTC)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(BudgetRead(monthly_amount=row.monthly_amount))


@router.get("/summary", response_model=ApiResponse[SummaryRead])
async def read_summary(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    year: int | None = None,
    month: int | None = None,
) -> ApiResponse[SummaryRead]:
    await require_membership(session, current_user.id, family_id)
    total = await month_total(session, family_id, year=year, month=month)
    budget = await get_budget(session, family_id)
    remaining = (budget - total) if budget is not None else None
    return ok(SummaryRead(month_total=total, budget=budget, remaining=remaining))


@router.post("/receipt-scan", response_model=ApiResponse[ReceiptScanResult])
async def receipt_scan(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    file: Annotated[UploadFile, File(...)],
) -> ApiResponse[ReceiptScanResult]:
    """Read a 小票 / 账单 / 付款截图 into a draft expense via the multimodal model.

    Returns a draft only — nothing is recorded and the photo is not persisted.
    The client pre-fills the 记一笔 form with the result for the user to confirm.
    AI not being configured or failing surfaces as a friendly error so the user
    can just type the amount instead.
    """
    await require_membership(session, current_user.id, family_id)

    content = await file.read(settings.max_upload_bytes + 1)
    if not content:
        raise AppError(ErrorCode.INVALID_IMAGE, "上传内容为空", status_code=400)
    if len(content) > settings.max_upload_bytes:
        raise AppError(
            ErrorCode.FILE_TOO_LARGE,
            f"文件超过上限 {settings.max_upload_bytes // (1024 * 1024)} MB",
            status_code=413,
        )
    content_type, _ext, _w, _h = validate_image(content)

    try:
        draft = await scan_receipt(content, content_type=content_type)
    except AiNotConfiguredError as exc:
        raise AppError(
            ErrorCode.INTERNAL, "小票识别暂未开通，请手动记一笔", status_code=503
        ) from exc
    except AiError as exc:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            "没认出小票内容，请手动记一笔",
            status_code=422,
        ) from exc
    return ok(draft)
