"""Retirement countdown routes — accounts, debts, plan, dashboard, ledger.

URL space follows the contract: `/families/{family_id}/plugins/retirement/...`.
Every route enforces membership via `require_membership`.
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
from app.plugins.retirement import service
from app.plugins.retirement.models import (
    RetireAccount,
    RetireAccountCreate,
    RetireAccountRead,
    RetireAccountUpdate,
    RetireDashboardRead,
    RetireDebt,
    RetireDebtCreate,
    RetireDebtRead,
    RetireDebtUpdate,
    RetireLedger,
    RetireLedgerRead,
    RetirePlan,
    RetirePlanRead,
    RetirePlanUpdate,
)
from app.services.membership import member_info_map as member_map

router = APIRouter(
    prefix="/families/{family_id}/plugins/retirement",
    tags=["retirement"],
)


async def _validate_from_account(
    session: SessionDep, family_id: UUID, account_id: UUID | None
) -> None:
    """A debt's linked deposit account must be a real account in this family."""
    if account_id is None:
        return
    account = await session.get(RetireAccount, account_id)
    if account is None or account.family_id != family_id:
        raise AppError(ErrorCode.VALIDATION_ERROR, "关联的账户不存在", status_code=422)


# ── Accounts ──────────────────────────────────────────────────────────────────


@router.get("/accounts", response_model=ApiResponse[list[RetireAccountRead]])
async def list_accounts(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[RetireAccountRead]]:
    await require_membership(session, current_user.id, family_id)
    rows = await service.get_accounts(session, family_id)
    members = await member_map(session, family_id)
    return ok([service.build_account_read(r, members) for r in rows])


@router.post("/accounts", response_model=ApiResponse[RetireAccountRead], status_code=201)
async def create_account(
    family_id: UUID,
    payload: RetireAccountCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RetireAccountRead]:
    await require_membership(session, current_user.id, family_id)
    row = RetireAccount(**payload.model_dump(), family_id=family_id, created_by=current_user.id)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    members = await member_map(session, family_id)
    return ok(service.build_account_read(row, members))


@router.put("/accounts/{account_id}", response_model=ApiResponse[RetireAccountRead])
async def update_account(
    family_id: UUID,
    account_id: UUID,
    payload: RetireAccountUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RetireAccountRead]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(RetireAccount, account_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "账户不存在", status_code=404)
    for key, value in payload.model_dump(exclude_unset=True).items():
        setattr(row, key, value)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    members = await member_map(session, family_id)
    return ok(service.build_account_read(row, members))


@router.delete("/accounts/{account_id}", response_model=ApiResponse[dict])
async def delete_account(
    family_id: UUID,
    account_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(RetireAccount, account_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "账户不存在", status_code=404)
    await session.delete(row)
    await session.commit()
    return ok({"deleted": str(account_id)})


# ── Debts ─────────────────────────────────────────────────────────────────────


@router.get("/debts", response_model=ApiResponse[list[RetireDebtRead]])
async def list_debts(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[RetireDebtRead]]:
    await require_membership(session, current_user.id, family_id)
    stmt = (
        select(RetireDebt)
        .where(RetireDebt.family_id == family_id)
        .order_by(RetireDebt.created_at.desc())
    )
    rows = (await session.execute(stmt)).scalars().all()
    members = await member_map(session, family_id)
    return ok([service.build_debt_read(r, members) for r in rows])


@router.post("/debts", response_model=ApiResponse[RetireDebtRead], status_code=201)
async def create_debt(
    family_id: UUID,
    payload: RetireDebtCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RetireDebtRead]:
    await require_membership(session, current_user.id, family_id)
    await _validate_from_account(session, family_id, payload.from_account_id)
    row = RetireDebt(**payload.model_dump(), family_id=family_id, created_by=current_user.id)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    members = await member_map(session, family_id)
    return ok(service.build_debt_read(row, members))


@router.put("/debts/{debt_id}", response_model=ApiResponse[RetireDebtRead])
async def update_debt(
    family_id: UUID,
    debt_id: UUID,
    payload: RetireDebtUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RetireDebtRead]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(RetireDebt, debt_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "负债不存在", status_code=404)
    updates = payload.model_dump(exclude_unset=True)
    if "from_account_id" in updates:
        await _validate_from_account(session, family_id, updates["from_account_id"])
    for key, value in updates.items():
        setattr(row, key, value)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    members = await member_map(session, family_id)
    return ok(service.build_debt_read(row, members))


@router.delete("/debts/{debt_id}", response_model=ApiResponse[dict])
async def delete_debt(
    family_id: UUID,
    debt_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(RetireDebt, debt_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "负债不存在", status_code=404)
    await session.delete(row)
    await session.commit()
    return ok({"deleted": str(debt_id)})


# ── Plan ──────────────────────────────────────────────────────────────────────


@router.get("/plan", response_model=ApiResponse[RetirePlanRead])
async def read_plan(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RetirePlanRead]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(RetirePlan, family_id)
    if row is None:
        return ok(RetirePlanRead())
    return ok(RetirePlanRead.model_validate(row, from_attributes=True))


@router.put("/plan", response_model=ApiResponse[RetirePlanRead])
async def set_plan(
    family_id: UUID,
    payload: RetirePlanUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RetirePlanRead]:
    await require_membership(session, current_user.id, family_id)
    updates = payload.model_dump(exclude_unset=True)
    row = await session.get(RetirePlan, family_id)
    if row is None:
        row = RetirePlan(family_id=family_id, updated_by=current_user.id)
        for key, value in updates.items():
            setattr(row, key, value)
    else:
        for key, value in updates.items():
            setattr(row, key, value)
        row.updated_by = current_user.id
        row.updated_at = datetime.now(UTC)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(RetirePlanRead.model_validate(row, from_attributes=True))


# ── Dashboard + ledger ────────────────────────────────────────────────────────


@router.get("/dashboard", response_model=ApiResponse[RetireDashboardRead])
async def read_dashboard(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RetireDashboardRead]:
    await require_membership(session, current_user.id, family_id)
    return ok(await service.compute_dashboard(session, family_id))


@router.get("/ledger", response_model=ApiResponse[list[RetireLedgerRead]])
async def list_ledger(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    limit: int = 100,
) -> ApiResponse[list[RetireLedgerRead]]:
    await require_membership(session, current_user.id, family_id)
    limit = max(1, min(limit, 500))
    stmt = (
        select(RetireLedger)
        .where(RetireLedger.family_id == family_id)
        .order_by(RetireLedger.created_at.desc())
        .limit(limit)
    )
    rows = (await session.execute(stmt)).scalars().all()
    return ok([service.build_ledger_read(r) for r in rows])
