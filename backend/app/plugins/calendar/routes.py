"""Calendar (家历) plugin routes — CRUD + complete/reopen + manual reminder.

URL space: `/families/{family_id}/plugins/calendar/...` (mounted under `/api/v1`).
Every route enforces family membership.
"""

from datetime import UTC, date, datetime
from uuid import UUID

from fastapi import APIRouter
from sqlmodel import select

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.models.user import User
from app.plugins.calendar.models import (
    CalendarItem,
    CalendarItemCreate,
    CalendarItemRead,
    CalendarItemUpdate,
)
from app.plugins.calendar.service import advance_occurrence, build_read
from app.services import notification as notification_service
from app.services.membership import MemberInfo
from app.services.membership import member_info_map as member_map

router = APIRouter(
    prefix="/families/{family_id}/plugins/calendar",
    tags=["calendar"],
)


async def _load(session: SessionDep, family_id: UUID, item_id: UUID) -> CalendarItem:
    row = await session.get(CalendarItem, item_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "日程不存在", status_code=404)
    return row


async def _validate_assignee(
    session: SessionDep, family_id: UUID, assignee: UUID | None
) -> None:
    if assignee is None:
        return
    try:
        await require_membership(session, assignee, family_id)
    except AppError as exc:
        raise AppError(
            ErrorCode.VALIDATION_ERROR, "指派的成员不在这个家庭里", status_code=400
        ) from exc


def _normalize(row: CalendarItem) -> None:
    """Keep cross-field invariants consistent.

    - An undated todo can't recur, have a time, or fire a reminder.
    - An all-day item has no time-of-day.
    """
    if row.event_date is None:
        row.repeat = "none"
        row.all_day = True
        row.start_minute = None
        row.notify_enabled = False
        row.notify_days_before = 0
        row.last_notified_occurrence = None
    elif row.all_day:
        row.start_minute = None


def _actor_name(members: dict[UUID, MemberInfo], actor: User) -> str:
    info = members.get(actor.id)
    return info.name if info else actor.display_name


async def _notify_newly_assigned(
    session: SessionDep,
    family_id: UUID,
    row: CalendarItem,
    actor: User,
    members: dict[UUID, MemberInfo],
) -> None:
    """Ping a newly-assigned member — once, never when self-assigned. Staged
    (not committed) so it lands in the same transaction as the write."""
    if row.assigned_to is None or row.assigned_to == actor.id:
        return
    await notification_service.notify_users(
        session,
        recipients=[row.assigned_to],
        notification_type="calendar_assigned",
        family_id=family_id,
        title=f"你有一项新安排：{row.title}",
        body=f"{_actor_name(members, actor)}把这件事交给了你 📅",
        icon_emoji=row.emoji or "📅",
        deeplink=f"wo://family/{family_id}/plugins/calendar",
    )


@router.get("/items", response_model=ApiResponse[list[CalendarItemRead]])
async def list_items(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    done: bool | None = None,
) -> ApiResponse[list[CalendarItemRead]]:
    """List the family's calendar items. `?done=false` for open ones,
    `?done=true` for finished; omit for all. Ordered open-first, then by next
    occurrence (undated todos last), so the client can render an agenda."""
    await require_membership(session, current_user.id, family_id)
    stmt = select(CalendarItem).where(CalendarItem.family_id == family_id)
    if done is not None:
        stmt = stmt.where(CalendarItem.done.is_(done))
    rows = list((await session.execute(stmt)).scalars().all())
    members = await member_map(session, family_id)
    today = date.today()
    reads = [build_read(r, members, today) for r in rows]
    # Open first; within open, soonest next_date first (None → far future);
    # within done, most-recently-completed first.
    reads.sort(
        key=lambda r: (
            r.done,
            r.next_date or date.max,
            r.start_minute if r.start_minute is not None else -1,
        )
    )
    return ok(reads)


@router.post("/items", response_model=ApiResponse[CalendarItemRead], status_code=201)
async def create_item(
    family_id: UUID,
    payload: CalendarItemCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[CalendarItemRead]:
    await require_membership(session, current_user.id, family_id)
    title = payload.title.strip()
    if not title:
        raise AppError(ErrorCode.VALIDATION_ERROR, "标题不能为空", status_code=400)
    await _validate_assignee(session, family_id, payload.assigned_to)
    row = CalendarItem(
        **payload.model_dump(),
        family_id=family_id,
        created_by=current_user.id,
    )
    row.title = title
    _normalize(row)
    session.add(row)
    members = await member_map(session, family_id)
    await _notify_newly_assigned(session, family_id, row, current_user, members)
    await session.commit()
    await session.refresh(row)
    return ok(build_read(row, members, date.today()))


@router.put("/items/{item_id}", response_model=ApiResponse[CalendarItemRead])
async def update_item(
    family_id: UUID,
    item_id: UUID,
    payload: CalendarItemUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[CalendarItemRead]:
    await require_membership(session, current_user.id, family_id)
    row = await _load(session, family_id, item_id)
    old_assignee = row.assigned_to
    updates = payload.model_dump(exclude_unset=True)
    if "assigned_to" in updates:
        await _validate_assignee(session, family_id, updates["assigned_to"])
    if "title" in updates and updates["title"] is not None:
        title = updates["title"].strip()
        if not title:
            raise AppError(ErrorCode.VALIDATION_ERROR, "标题不能为空", status_code=400)
        updates["title"] = title
    for key, value in updates.items():
        setattr(row, key, value)
    _normalize(row)
    session.add(row)
    members = await member_map(session, family_id)
    if row.assigned_to != old_assignee:
        await _notify_newly_assigned(session, family_id, row, current_user, members)
    await session.commit()
    await session.refresh(row)
    return ok(build_read(row, members, date.today()))


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


@router.post("/items/{item_id}/complete", response_model=ApiResponse[CalendarItemRead])
async def complete_item(
    family_id: UUID,
    item_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[CalendarItemRead]:
    """Complete an item. A recurring item rolls its `event_date` forward to the
    next occurrence (so it stays open for next time); a single item / undated
    todo is marked done. Idempotent for single items."""
    await require_membership(session, current_user.id, family_id)
    row = await _load(session, family_id, item_id)
    today = date.today()
    if row.event_date is not None and row.repeat != "none":
        row.event_date = advance_occurrence(row.event_date, row.repeat, today)
        row.last_notified_occurrence = None
        row.done = False
        row.completed_at = None
    elif not row.done:
        row.done = True
        row.completed_at = datetime.now(UTC)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    members = await member_map(session, family_id)
    return ok(build_read(row, members, today))


@router.post("/items/{item_id}/reopen", response_model=ApiResponse[CalendarItemRead])
async def reopen_item(
    family_id: UUID,
    item_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[CalendarItemRead]:
    """Mark a done item as not-done again (idempotent)."""
    await require_membership(session, current_user.id, family_id)
    row = await _load(session, family_id, item_id)
    if row.done:
        row.done = False
        row.completed_at = None
        session.add(row)
        await session.commit()
        await session.refresh(row)
    members = await member_map(session, family_id)
    return ok(build_read(row, members, date.today()))


@router.post("/items/{item_id}/remind", response_model=ApiResponse[dict])
async def remind_item(
    family_id: UUID,
    item_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    """Manually nudge the assignee. The item must be assigned and still open."""
    await require_membership(session, current_user.id, family_id)
    row = await _load(session, family_id, item_id)
    if row.assigned_to is None:
        raise AppError(ErrorCode.VALIDATION_ERROR, "这件事还没有指派负责人", status_code=400)
    if row.done:
        raise AppError(ErrorCode.VALIDATION_ERROR, "这件事已经完成了", status_code=400)

    members = await member_map(session, family_id)
    await notification_service.notify_users(
        session,
        recipients=[row.assigned_to],
        notification_type="calendar_remind",
        family_id=family_id,
        title=f"记得：{row.title}",
        body=f"{_actor_name(members, current_user)}提醒你这件事 📅",
        icon_emoji=row.emoji or "📅",
        deeplink=f"wo://family/{family_id}/plugins/calendar",
    )
    await session.commit()
    return ok({"reminded": str(row.assigned_to)})
