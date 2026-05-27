"""Chore plugin routes — CRUD + done toggle + manual reminder.

URL space follows the contract: `/families/{family_id}/plugins/chore/...`.
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
from app.models.user import User
from app.plugins.chore.models import Chore, ChoreCreate, ChoreRead, ChoreUpdate
from app.plugins.chore.service import build_read
from app.services import notification as notification_service
from app.services.membership import MemberInfo
from app.services.membership import member_info_map as member_map

router = APIRouter(
    prefix="/families/{family_id}/plugins/chore",
    tags=["chore"],
)


async def _load_chore(session: SessionDep, family_id: UUID, chore_id: UUID) -> Chore:
    row = await session.get(Chore, chore_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "家务不存在", status_code=404)
    return row


async def _validate_assignee(session: SessionDep, family_id: UUID, assignee: UUID | None) -> None:
    """An assignee, when given, must be an active member of this family."""
    if assignee is None:
        return
    try:
        await require_membership(session, assignee, family_id)
    except AppError as exc:
        raise AppError(
            ErrorCode.VALIDATION_ERROR, "指派的成员不在这个家庭里", status_code=400
        ) from exc


def _actor_name(members: dict[UUID, MemberInfo], actor: User) -> str:
    """The actor's family display name, falling back to their global name."""
    info = members.get(actor.id)
    return info.name if info else actor.display_name


async def _notify_newly_assigned(
    session: SessionDep,
    family_id: UUID,
    chore: Chore,
    actor: User,
    members: dict[UUID, tuple[str, str]],
) -> None:
    """Ping a chore's assignee that it's now theirs — once, and never when the
    actor assigned it to themselves. Staged (not committed) so it lands in the
    same transaction as the chore write."""
    if chore.assigned_to is None or chore.assigned_to == actor.id:
        return
    await notification_service.notify_users(
        session,
        recipients=[chore.assigned_to],
        notification_type="chore_assigned",
        family_id=family_id,
        title=f"你被安排了家务：{chore.title}",
        body=f"{_actor_name(members, actor)}把这件家务交给了你 🧹",
        icon_emoji=chore.emoji or "🧹",
        deeplink=f"wo://family/{family_id}/plugins/chore",
    )


@router.get("/chores", response_model=ApiResponse[list[ChoreRead]])
async def list_chores(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    done: bool | None = None,
) -> ApiResponse[list[ChoreRead]]:
    """List chores. `?done=false` for open ones, `?done=true` for finished;
    omit for all. Open chores first, then by recency."""
    await require_membership(session, current_user.id, family_id)
    stmt = (
        select(Chore)
        .where(Chore.family_id == family_id)
        .order_by(Chore.done, Chore.created_at.desc())
    )
    if done is not None:
        stmt = stmt.where(Chore.done.is_(done))
    rows = (await session.execute(stmt)).scalars().all()
    members = await member_map(session, family_id)
    return ok([build_read(r, members) for r in rows])


@router.post("/chores", response_model=ApiResponse[ChoreRead], status_code=201)
async def create_chore(
    family_id: UUID,
    payload: ChoreCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[ChoreRead]:
    await require_membership(session, current_user.id, family_id)
    title = payload.title.strip()
    if not title:
        raise AppError(ErrorCode.VALIDATION_ERROR, "家务名不能为空", status_code=400)
    await _validate_assignee(session, family_id, payload.assigned_to)
    row = Chore(
        **payload.model_dump(),
        family_id=family_id,
        created_by=current_user.id,
    )
    row.title = title
    session.add(row)
    members = await member_map(session, family_id)
    await _notify_newly_assigned(session, family_id, row, current_user, members)
    await session.commit()
    await session.refresh(row)
    return ok(build_read(row, members))


@router.put("/chores/{chore_id}", response_model=ApiResponse[ChoreRead])
async def update_chore(
    family_id: UUID,
    chore_id: UUID,
    payload: ChoreUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[ChoreRead]:
    await require_membership(session, current_user.id, family_id)
    row = await _load_chore(session, family_id, chore_id)
    old_assignee = row.assigned_to
    updates = payload.model_dump(exclude_unset=True)
    if "assigned_to" in updates:
        await _validate_assignee(session, family_id, updates["assigned_to"])
    # Keep completed_at in sync when `done` is toggled through a plain update.
    if "done" in updates and updates["done"] is not None:
        updates["completed_at"] = datetime.now(UTC) if updates["done"] else None
    for key, value in updates.items():
        setattr(row, key, value)
    session.add(row)
    members = await member_map(session, family_id)
    # Only ping on a genuine reassignment, not on unrelated edits (title, note…).
    if row.assigned_to != old_assignee:
        await _notify_newly_assigned(session, family_id, row, current_user, members)
    await session.commit()
    await session.refresh(row)
    return ok(build_read(row, members))


@router.delete("/chores/{chore_id}", response_model=ApiResponse[dict])
async def delete_chore(
    family_id: UUID,
    chore_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await require_membership(session, current_user.id, family_id)
    row = await _load_chore(session, family_id, chore_id)
    await session.delete(row)
    await session.commit()
    return ok({"deleted": str(chore_id)})


@router.post("/chores/{chore_id}/complete", response_model=ApiResponse[ChoreRead])
async def complete_chore(
    family_id: UUID,
    chore_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[ChoreRead]:
    """Mark a chore done (idempotent)."""
    await require_membership(session, current_user.id, family_id)
    row = await _load_chore(session, family_id, chore_id)
    if not row.done:
        row.done = True
        row.completed_at = datetime.now(UTC)
        session.add(row)
        await session.commit()
        await session.refresh(row)
    members = await member_map(session, family_id)
    return ok(build_read(row, members))


@router.post("/chores/{chore_id}/reopen", response_model=ApiResponse[ChoreRead])
async def reopen_chore(
    family_id: UUID,
    chore_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[ChoreRead]:
    """Mark a done chore as not-done again (idempotent)."""
    await require_membership(session, current_user.id, family_id)
    row = await _load_chore(session, family_id, chore_id)
    if row.done:
        row.done = False
        row.completed_at = None
        session.add(row)
        await session.commit()
        await session.refresh(row)
    members = await member_map(session, family_id)
    return ok(build_read(row, members))


@router.post("/chores/{chore_id}/remind", response_model=ApiResponse[dict])
async def remind_chore(
    family_id: UUID,
    chore_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    """Manually nudge the assignee with a notification. The chore must be
    assigned and still open."""
    await require_membership(session, current_user.id, family_id)
    row = await _load_chore(session, family_id, chore_id)
    if row.assigned_to is None:
        raise AppError(ErrorCode.VALIDATION_ERROR, "这件家务还没有指派负责人", status_code=400)
    if row.done:
        raise AppError(ErrorCode.VALIDATION_ERROR, "这件家务已经完成了", status_code=400)

    members = await member_map(session, family_id)
    await notification_service.notify_users(
        session,
        recipients=[row.assigned_to],
        notification_type="chore_reminder",
        family_id=family_id,
        title=f"记得做家务：{row.title}",
        body=f"{_actor_name(members, current_user)}提醒你完成这件家务 💪",
        icon_emoji=row.emoji or "🧹",
        deeplink=f"wo://family/{family_id}/plugins/chore",
    )
    await session.commit()
    return ok({"reminded": str(row.assigned_to)})
