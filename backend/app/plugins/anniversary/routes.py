"""Anniversary plugin routes — CRUD over family dates.

URL space follows the contract: `/families/{family_id}/plugins/anniversary/...`.
Every route enforces membership via `require_membership`.
"""

from uuid import UUID

from fastapi import APIRouter
from sqlmodel import select

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.plugins.anniversary.models import (
    Anniversary,
    AnniversaryCreate,
    AnniversaryRead,
    AnniversaryUpdate,
)

router = APIRouter(
    prefix="/families/{family_id}/plugins/anniversary",
    tags=["anniversary"],
)


@router.get("/dates", response_model=ApiResponse[list[AnniversaryRead]])
async def list_dates(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[AnniversaryRead]]:
    await require_membership(session, current_user.id, family_id)
    stmt = (
        select(Anniversary)
        .where(Anniversary.family_id == family_id)
        .order_by(Anniversary.event_date)
    )
    rows = (await session.execute(stmt)).scalars().all()
    return ok([AnniversaryRead.model_validate(r, from_attributes=True) for r in rows])


@router.post(
    "/dates",
    response_model=ApiResponse[AnniversaryRead],
    status_code=201,
)
async def create_date(
    family_id: UUID,
    payload: AnniversaryCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[AnniversaryRead]:
    await require_membership(session, current_user.id, family_id)
    row = Anniversary(
        **payload.model_dump(),
        family_id=family_id,
        created_by=current_user.id,
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(AnniversaryRead.model_validate(row, from_attributes=True))


@router.put("/dates/{date_id}", response_model=ApiResponse[AnniversaryRead])
async def update_date(
    family_id: UUID,
    date_id: UUID,
    payload: AnniversaryUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[AnniversaryRead]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(Anniversary, date_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "纪念日不存在", status_code=404)
    for key, value in payload.model_dump(exclude_unset=True).items():
        setattr(row, key, value)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return ok(AnniversaryRead.model_validate(row, from_attributes=True))


@router.delete("/dates/{date_id}", response_model=ApiResponse[dict])
async def delete_date(
    family_id: UUID,
    date_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    row = await session.get(Anniversary, date_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "纪念日不存在", status_code=404)
    await session.delete(row)
    await session.commit()
    return ok({"deleted": str(date_id)})
