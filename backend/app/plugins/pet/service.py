"""Business logic for 宠物日常."""

from __future__ import annotations

import base64
import json
from calendar import monthrange
from datetime import UTC, date, datetime, timedelta
from decimal import Decimal
from uuid import UUID

from sqlalchemy import func
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.errors import AppError, ErrorCode
from app.core.ids import new_uuid7
from app.core.permissions import require_admin, require_membership
from app.models.membership import Membership
from app.models.pet import Pet, to_pet_read
from app.models.plugin import InstalledPlugin
from app.models.user import User
from app.plugins.pet.models import (
    AttachmentRead,
    CarePlanCreate,
    CarePlanRead,
    CarePlanUpdate,
    FollowUpCreate,
    PetCarePlan,
    PetDashboard,
    PetListItem,
    PetRecord,
    PetRecordAttachment,
    PetRecordType,
    PlanCompletionCreate,
    RecordCreate,
    RecordRead,
    RecordTypeCreate,
    RecordTypeRead,
    RecordTypeUpdate,
    RecordUpdate,
    WeightPoint,
)
from app.plugins.registry import PluginPreview
from app.services.membership import MemberInfo, author_avatar_url, member_info_map

DEFAULT_RECORD_TYPES: tuple[tuple[str, str, str], ...] = (
    ("喂食", "🍚", "general"),
    ("遛狗", "🦮", "general"),
    ("铲砂", "🧹", "general"),
    ("喂药", "💊", "general"),
    ("驱虫", "🛡️", "general"),
    ("疫苗", "💉", "general"),
    ("体检", "🩺", "general"),
    ("体重", "⚖️", "weight"),
    ("洗护", "🫧", "general"),
    ("其他", "🐾", "general"),
)
VALID_DATA_KINDS = {"general", "weight"}
VALID_RECURRENCE_UNITS = {"none", "day", "week", "month", "year"}


def _clean_name(value: str, label: str = "名称") -> str:
    value = value.strip()
    if not value:
        raise AppError(ErrorCode.VALIDATION_ERROR, f"{label}不能为空", status_code=400)
    return value


async def load_active_pet(session: AsyncSession, family_id: UUID, pet_id: UUID) -> Pet:
    pet = await session.get(Pet, pet_id)
    if pet is None or pet.family_id != family_id or pet.archived_at is not None:
        raise AppError(ErrorCode.NOT_FOUND, "宠物不存在", status_code=404)
    return pet


async def ensure_default_types(session: AsyncSession, family_id: UUID) -> None:
    rows = [
        {
            "id": new_uuid7(),
            "family_id": family_id,
            "name": name,
            "emoji": emoji,
            "data_kind": data_kind,
            "sort_order": index,
            "created_at": datetime.now(UTC),
        }
        for index, (name, emoji, data_kind) in enumerate(DEFAULT_RECORD_TYPES)
    ]
    stmt = (
        pg_insert(PetRecordType)
        .values(rows)
        .on_conflict_do_nothing(constraint="uq_pet_record_types_family_name")
    )
    await session.execute(stmt)
    await session.commit()


def type_read(row: PetRecordType) -> RecordTypeRead:
    return RecordTypeRead(
        id=row.id,
        family_id=row.family_id,
        name=row.name,
        emoji=row.emoji,
        data_kind=row.data_kind,  # type: ignore[arg-type]
        sort_order=row.sort_order,
        archived=row.archived_at is not None,
    )


async def list_record_types(
    session: AsyncSession, family_id: UUID, user: User, *, include_archived: bool = False
) -> list[PetRecordType]:
    await require_membership(session, user.id, family_id)
    await ensure_default_types(session, family_id)
    stmt = select(PetRecordType).where(PetRecordType.family_id == family_id)
    if not include_archived:
        stmt = stmt.where(PetRecordType.archived_at.is_(None))
    stmt = stmt.order_by(PetRecordType.sort_order, PetRecordType.created_at)
    return list((await session.execute(stmt)).scalars().all())


async def load_record_type(
    session: AsyncSession,
    family_id: UUID,
    type_id: UUID,
    *,
    active_only: bool = True,
) -> PetRecordType:
    row = await session.get(PetRecordType, type_id)
    if row is None or row.family_id != family_id or (active_only and row.archived_at is not None):
        raise AppError(ErrorCode.NOT_FOUND, "记录类型不存在", status_code=404)
    return row


async def create_record_type(
    session: AsyncSession, family_id: UUID, payload: RecordTypeCreate, user: User
) -> PetRecordType:
    membership = await require_membership(session, user.id, family_id)
    require_admin(membership)
    name = _clean_name(payload.name, "类型名称")
    if payload.data_kind not in VALID_DATA_KINDS:
        raise AppError(ErrorCode.VALIDATION_ERROR, "数据类型不合法", status_code=400)
    max_sort = int(
        (
            await session.execute(
                select(func.coalesce(func.max(PetRecordType.sort_order), -1)).where(
                    PetRecordType.family_id == family_id
                )
            )
        ).scalar_one()
    )
    row = PetRecordType(
        family_id=family_id,
        name=name,
        emoji=payload.emoji,
        data_kind=payload.data_kind,
        sort_order=max_sort + 1,
    )
    session.add(row)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise AppError(ErrorCode.VALIDATION_ERROR, "记录类型名称已存在", status_code=409) from exc
    await session.refresh(row)
    return row


async def update_record_type(
    session: AsyncSession,
    family_id: UUID,
    type_id: UUID,
    payload: RecordTypeUpdate,
    user: User,
) -> PetRecordType:
    membership = await require_membership(session, user.id, family_id)
    require_admin(membership)
    row = await load_record_type(session, family_id, type_id, active_only=False)
    updates = payload.model_dump(exclude_unset=True)
    archived = updates.pop("archived", None)
    if updates.get("name") is not None:
        updates["name"] = _clean_name(updates["name"], "类型名称")
    requested_kind = updates.get("data_kind")
    if requested_kind is not None and requested_kind != row.data_kind:
        used = int(
            (
                await session.execute(
                    select(func.count())
                    .select_from(PetRecord)
                    .where(PetRecord.record_type_id == row.id)
                )
            ).scalar_one()
        )
        if used:
            raise AppError(
                ErrorCode.VALIDATION_ERROR,
                "已有记录引用该类型，不能修改数据能力",
                status_code=409,
            )
    for key, value in updates.items():
        setattr(row, key, value)
    if archived is not None:
        row.archived_at = datetime.now(UTC) if archived else None
    session.add(row)
    try:
        await session.commit()
    except IntegrityError as exc:
        await session.rollback()
        raise AppError(ErrorCode.VALIDATION_ERROR, "记录类型名称已存在", status_code=409) from exc
    await session.refresh(row)
    return row


async def reorder_record_types(
    session: AsyncSession, family_id: UUID, ids: list[UUID], user: User
) -> list[PetRecordType]:
    membership = await require_membership(session, user.id, family_id)
    require_admin(membership)
    rows = list(
        (
            await session.execute(
                select(PetRecordType).where(
                    PetRecordType.family_id == family_id,
                    PetRecordType.id.in_(ids),
                )
            )
        )
        .scalars()
        .all()
    )
    if len(rows) != len(set(ids)):
        raise AppError(ErrorCode.VALIDATION_ERROR, "排序中包含无效类型", status_code=400)
    by_id = {row.id: row for row in rows}
    for order, type_id in enumerate(ids):
        by_id[type_id].sort_order = order
        session.add(by_id[type_id])
    await session.commit()
    return [by_id[type_id] for type_id in ids]


def _clamped_date(year: int, month: int, day: int) -> date:
    return date(year, month, min(day, monthrange(year, month)[1]))


def advance_date(current: date, unit: str, interval: int) -> date | None:
    if unit == "none":
        return None
    if interval < 1:
        raise ValueError("interval must be positive")
    if unit == "day":
        return current + timedelta(days=interval)
    if unit == "week":
        return current + timedelta(weeks=interval)
    if unit == "month":
        month_index = current.year * 12 + current.month - 1 + interval
        return _clamped_date(month_index // 12, month_index % 12 + 1, current.day)
    if unit == "year":
        return _clamped_date(current.year + interval, current.month, current.day)
    raise ValueError(f"unknown recurrence unit: {unit}")


async def _type_map(
    session: AsyncSession, family_id: UUID, type_ids: set[UUID] | None = None
) -> dict[UUID, PetRecordType]:
    stmt = select(PetRecordType).where(PetRecordType.family_id == family_id)
    if type_ids is not None:
        if not type_ids:
            return {}
        stmt = stmt.where(PetRecordType.id.in_(type_ids))
    return {row.id: row for row in (await session.execute(stmt)).scalars().all()}


def plan_read(
    row: PetCarePlan,
    record_type: PetRecordType,
    today: date | None = None,
) -> CarePlanRead:
    today = today or date.today()
    return CarePlanRead(
        id=row.id,
        family_id=row.family_id,
        pet_id=row.pet_id,
        record_type_id=row.record_type_id,
        type_name=record_type.name,
        type_emoji=record_type.emoji,
        data_kind=record_type.data_kind,  # type: ignore[arg-type]
        name=row.name,
        note=row.note,
        recurrence_unit=row.recurrence_unit,  # type: ignore[arg-type]
        recurrence_interval=row.recurrence_interval,
        next_due_date=row.next_due_date,
        active=row.active,
        created_by=row.created_by,
        created_at=row.created_at,
        updated_at=row.updated_at,
        days_until=(row.next_due_date - today).days if row.next_due_date else None,
    )


async def load_plan(
    session: AsyncSession, family_id: UUID, pet_id: UUID, plan_id: UUID
) -> PetCarePlan:
    row = await session.get(PetCarePlan, plan_id)
    if row is None or row.family_id != family_id or row.pet_id != pet_id:
        raise AppError(ErrorCode.NOT_FOUND, "照护计划不存在", status_code=404)
    return row


def _validate_plan_values(unit: str, interval: int, next_due: date | None) -> None:
    if unit not in VALID_RECURRENCE_UNITS:
        raise AppError(ErrorCode.VALIDATION_ERROR, "周期单位不合法", status_code=400)
    if interval < 1:
        raise AppError(ErrorCode.VALIDATION_ERROR, "周期间隔必须大于 0", status_code=400)
    if next_due is None:
        raise AppError(ErrorCode.VALIDATION_ERROR, "请设置下次日期", status_code=400)


async def list_plans(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    user: User,
    *,
    active: bool | None = None,
) -> tuple[list[PetCarePlan], dict[UUID, PetRecordType]]:
    await require_membership(session, user.id, family_id)
    await load_active_pet(session, family_id, pet_id)
    stmt = select(PetCarePlan).where(
        PetCarePlan.family_id == family_id, PetCarePlan.pet_id == pet_id
    )
    if active is not None:
        stmt = stmt.where(PetCarePlan.active.is_(active))
    stmt = stmt.order_by(
        PetCarePlan.active.desc(),
        PetCarePlan.next_due_date,
        PetCarePlan.created_at,
    )
    rows = list((await session.execute(stmt)).scalars().all())
    return rows, await _type_map(session, family_id, {r.record_type_id for r in rows})


async def create_plan_row(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    payload: CarePlanCreate,
    user_id: UUID,
) -> tuple[PetCarePlan, PetRecordType]:
    await load_active_pet(session, family_id, pet_id)
    record_type = await load_record_type(session, family_id, payload.record_type_id)
    _validate_plan_values(
        payload.recurrence_unit, payload.recurrence_interval, payload.next_due_date
    )
    row = PetCarePlan(
        family_id=family_id,
        pet_id=pet_id,
        record_type_id=record_type.id,
        name=_clean_name(payload.name, "计划名称"),
        note=payload.note,
        recurrence_unit=payload.recurrence_unit,
        recurrence_interval=payload.recurrence_interval,
        next_due_date=payload.next_due_date,
        created_by=user_id,
    )
    session.add(row)
    await session.flush()
    return row, record_type


async def create_plan(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    payload: CarePlanCreate,
    user: User,
) -> tuple[PetCarePlan, PetRecordType]:
    await require_membership(session, user.id, family_id)
    row, record_type = await create_plan_row(session, family_id, pet_id, payload, user.id)
    await session.commit()
    await session.refresh(row)
    return row, record_type


async def _require_owner_or_creator(
    membership: Membership, user_id: UUID, created_by: UUID | None
) -> None:
    if membership.role not in ("owner", "admin") and created_by != user_id:
        raise AppError(ErrorCode.FORBIDDEN, "只能修改自己创建的内容", status_code=403)


async def update_plan(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    plan_id: UUID,
    payload: CarePlanUpdate,
    user: User,
) -> tuple[PetCarePlan, PetRecordType]:
    membership = await require_membership(session, user.id, family_id)
    await load_active_pet(session, family_id, pet_id)
    row = await load_plan(session, family_id, pet_id, plan_id)
    await _require_owner_or_creator(membership, user.id, row.created_by)
    updates = payload.model_dump(exclude_unset=True)
    if updates.get("name") is not None:
        updates["name"] = _clean_name(updates["name"], "计划名称")
    type_id = updates.get("record_type_id", row.record_type_id)
    record_type = await load_record_type(session, family_id, type_id)
    unit = updates.get("recurrence_unit", row.recurrence_unit)
    interval = updates.get("recurrence_interval", row.recurrence_interval)
    due = updates.get("next_due_date", row.next_due_date)
    if updates.get("active", row.active):
        _validate_plan_values(unit, interval, due)
    due_changed = "next_due_date" in updates and updates["next_due_date"] != row.next_due_date
    for key, value in updates.items():
        setattr(row, key, value)
    if due_changed:
        row.last_notified_due_date = None
    row.updated_at = datetime.now(UTC)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return row, record_type


async def delete_plan(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    plan_id: UUID,
    user: User,
) -> None:
    membership = await require_membership(session, user.id, family_id)
    row = await load_plan(session, family_id, pet_id, plan_id)
    await _require_owner_or_creator(membership, user.id, row.created_by)
    await session.delete(row)
    await session.commit()


def attachment_read(row: PetRecordAttachment) -> AttachmentRead:
    return AttachmentRead(
        id=row.id,
        original_filename=row.original_filename,
        content_type=row.content_type,
        size_bytes=row.size_bytes,
        sort_order=row.sort_order,
        url=(
            f"/api/v1/families/{row.family_id}/plugins/pet/records/"
            f"{row.record_id}/attachments/{row.id}"
        ),
    )


def record_read(
    row: PetRecord,
    info: dict[UUID, MemberInfo],
    attachments: list[PetRecordAttachment] | None = None,
) -> RecordRead:
    member = info.get(row.created_by) if row.created_by else None
    return RecordRead(
        id=row.id,
        family_id=row.family_id,
        pet_id=row.pet_id,
        record_type_id=row.record_type_id,
        type_name=row.type_name_snapshot,
        type_emoji=row.type_emoji_snapshot,
        data_kind=row.data_kind_snapshot,  # type: ignore[arg-type]
        name=row.name,
        note=row.note,
        occurred_on=row.occurred_on,
        next_due_date=row.next_due_date,
        weight_kg=row.weight_kg,
        plan_id=row.plan_id,
        scheduled_due_date=row.scheduled_due_date,
        created_by=row.created_by,
        created_at=row.created_at,
        updated_at=row.updated_at,
        creator_name=member.name if member else None,
        creator_emoji=member.emoji if member else None,
        creator_avatar_url=author_avatar_url(row.family_id, row.created_by, member),
        attachments=[attachment_read(a) for a in (attachments or [])],
    )


async def load_record(
    session: AsyncSession, family_id: UUID, pet_id: UUID, record_id: UUID
) -> PetRecord:
    row = await session.get(PetRecord, record_id)
    if row is None or row.family_id != family_id or row.pet_id != pet_id:
        raise AppError(ErrorCode.NOT_FOUND, "健康记录不存在", status_code=404)
    return row


def _validate_weight(record_type: PetRecordType, weight: Decimal | None) -> None:
    if record_type.data_kind == "weight" and weight is None:
        raise AppError(ErrorCode.VALIDATION_ERROR, "请填写体重", status_code=400)
    if record_type.data_kind != "weight" and weight is not None:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            "只有体重类型可以填写体重数值",
            status_code=400,
        )


async def _upsert_follow_up(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    record_type: PetRecordType,
    record_name: str,
    follow_up: FollowUpCreate,
    user_id: UUID,
) -> PetCarePlan:
    _validate_plan_values(
        follow_up.recurrence_unit,
        follow_up.recurrence_interval,
        follow_up.next_due_date,
    )
    if follow_up.plan_id:
        plan = await load_plan(session, family_id, pet_id, follow_up.plan_id)
        plan.record_type_id = record_type.id
        plan.name = record_name
        plan.recurrence_unit = follow_up.recurrence_unit
        plan.recurrence_interval = follow_up.recurrence_interval
        plan.next_due_date = follow_up.next_due_date
        plan.active = True
        plan.last_notified_due_date = None
        plan.updated_at = datetime.now(UTC)
        session.add(plan)
        return plan
    plan = PetCarePlan(
        family_id=family_id,
        pet_id=pet_id,
        record_type_id=record_type.id,
        name=record_name,
        recurrence_unit=follow_up.recurrence_unit,
        recurrence_interval=follow_up.recurrence_interval,
        next_due_date=follow_up.next_due_date,
        created_by=user_id,
    )
    session.add(plan)
    await session.flush()
    return plan


async def create_record(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    payload: RecordCreate,
    user: User,
) -> PetRecord:
    await require_membership(session, user.id, family_id)
    await load_active_pet(session, family_id, pet_id)
    record_type = await load_record_type(session, family_id, payload.record_type_id)
    _validate_weight(record_type, payload.weight_kg)
    name = _clean_name(payload.name, "记录名称")
    plan: PetCarePlan | None = None
    if payload.follow_up:
        plan = await _upsert_follow_up(
            session,
            family_id,
            pet_id,
            record_type,
            name,
            payload.follow_up,
            user.id,
        )
    row = PetRecord(
        family_id=family_id,
        pet_id=pet_id,
        record_type_id=record_type.id,
        type_name_snapshot=record_type.name,
        type_emoji_snapshot=record_type.emoji,
        data_kind_snapshot=record_type.data_kind,
        name=name,
        note=payload.note,
        occurred_on=payload.occurred_on,
        next_due_date=(
            payload.follow_up.next_due_date if payload.follow_up else payload.next_due_date
        ),
        weight_kg=payload.weight_kg,
        plan_id=plan.id if plan else None,
        created_by=user.id,
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return row


async def update_record(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    record_id: UUID,
    payload: RecordUpdate,
    user: User,
) -> PetRecord:
    membership = await require_membership(session, user.id, family_id)
    row = await load_record(session, family_id, pet_id, record_id)
    await _require_owner_or_creator(membership, user.id, row.created_by)
    updates = payload.model_dump(exclude_unset=True)
    if updates.get("name") is not None:
        updates["name"] = _clean_name(updates["name"], "记录名称")
    record_type: PetRecordType | None = None
    if "record_type_id" in updates and updates["record_type_id"] is not None:
        record_type = await load_record_type(session, family_id, updates["record_type_id"])
        row.type_name_snapshot = record_type.name
        row.type_emoji_snapshot = record_type.emoji
        row.data_kind_snapshot = record_type.data_kind
    else:
        if row.record_type_id:
            record_type = await load_record_type(
                session, family_id, row.record_type_id, active_only=False
            )
    effective_kind = record_type.data_kind if record_type else row.data_kind_snapshot
    effective_weight = updates.get("weight_kg", row.weight_kg)
    if effective_kind == "weight" and effective_weight is None:
        raise AppError(ErrorCode.VALIDATION_ERROR, "请填写体重", status_code=400)
    if effective_kind != "weight" and effective_weight is not None:
        raise AppError(ErrorCode.VALIDATION_ERROR, "普通记录不能填写体重", status_code=400)
    for key, value in updates.items():
        setattr(row, key, value)
    row.updated_at = datetime.now(UTC)
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return row


def encode_cursor(row: PetRecord) -> str:
    raw = json.dumps(
        [row.occurred_on.isoformat(), row.created_at.isoformat(), str(row.id)],
        separators=(",", ":"),
    ).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_cursor(cursor: str) -> tuple[date, datetime, UUID]:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        values = json.loads(base64.urlsafe_b64decode(padded).decode())
        return date.fromisoformat(values[0]), datetime.fromisoformat(values[1]), UUID(values[2])
    except Exception as exc:
        raise AppError(ErrorCode.VALIDATION_ERROR, "cursor 无效", status_code=400) from exc


async def record_page(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    user: User,
    *,
    cursor: str | None = None,
    limit: int = 20,
) -> tuple[list[RecordRead], str | None, int]:
    await require_membership(session, user.id, family_id)
    await load_active_pet(session, family_id, pet_id)
    stmt = select(PetRecord).where(PetRecord.family_id == family_id, PetRecord.pet_id == pet_id)
    if cursor:
        c_date, c_created, c_id = decode_cursor(cursor)
        stmt = stmt.where(
            (PetRecord.occurred_on < c_date)
            | ((PetRecord.occurred_on == c_date) & (PetRecord.created_at < c_created))
            | (
                (PetRecord.occurred_on == c_date)
                & (PetRecord.created_at == c_created)
                & (PetRecord.id < c_id)
            )
        )
    stmt = stmt.order_by(
        PetRecord.occurred_on.desc(), PetRecord.created_at.desc(), PetRecord.id.desc()
    ).limit(limit + 1)
    rows = list((await session.execute(stmt)).scalars().all())
    has_more = len(rows) > limit
    page = rows[:limit]
    total = int(
        (
            await session.execute(
                select(func.count())
                .select_from(PetRecord)
                .where(PetRecord.family_id == family_id, PetRecord.pet_id == pet_id)
            )
        ).scalar_one()
    )
    if not page:
        return [], None, total
    ids = [row.id for row in page]
    attachment_rows = list(
        (
            await session.execute(
                select(PetRecordAttachment)
                .where(PetRecordAttachment.record_id.in_(ids))
                .order_by(PetRecordAttachment.sort_order, PetRecordAttachment.created_at)
            )
        )
        .scalars()
        .all()
    )
    by_record: dict[UUID, list[PetRecordAttachment]] = {record_id: [] for record_id in ids}
    for attachment in attachment_rows:
        by_record[attachment.record_id].append(attachment)
    info = await member_info_map(session, family_id)
    reads = [record_read(row, info, by_record[row.id]) for row in page]
    return reads, encode_cursor(page[-1]) if has_more else None, total


async def delete_record(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    record_id: UUID,
    user: User,
) -> list[str]:
    membership = await require_membership(session, user.id, family_id)
    row = await load_record(session, family_id, pet_id, record_id)
    await _require_owner_or_creator(membership, user.id, row.created_by)
    attachments = list(
        (
            await session.execute(
                select(PetRecordAttachment).where(PetRecordAttachment.record_id == row.id)
            )
        )
        .scalars()
        .all()
    )
    keys = [attachment.storage_key for attachment in attachments]
    await session.delete(row)
    await session.commit()
    return keys


async def complete_plan(
    session: AsyncSession,
    family_id: UUID,
    pet_id: UUID,
    plan_id: UUID,
    payload: PlanCompletionCreate,
    user: User,
) -> PetRecord:
    await require_membership(session, user.id, family_id)
    await load_active_pet(session, family_id, pet_id)
    plan = await load_plan(session, family_id, pet_id, plan_id)
    if not plan.active or plan.next_due_date is None:
        raise AppError(ErrorCode.VALIDATION_ERROR, "照护计划当前不可完成", status_code=409)
    scheduled_due = payload.scheduled_due_date or plan.next_due_date
    existing_stmt = select(PetRecord).where(
        PetRecord.plan_id == plan.id, PetRecord.scheduled_due_date == scheduled_due
    )
    existing = (await session.execute(existing_stmt)).scalar_one_or_none()
    if existing:
        return existing
    record_type = await load_record_type(session, family_id, plan.record_type_id, active_only=False)
    _validate_weight(record_type, payload.weight_kg)
    occurred_on = payload.occurred_on or date.today()
    next_due = payload.next_due_date_override
    if next_due is None:
        next_due = advance_date(occurred_on, plan.recurrence_unit, plan.recurrence_interval)
    row = PetRecord(
        family_id=family_id,
        pet_id=pet_id,
        record_type_id=record_type.id,
        type_name_snapshot=record_type.name,
        type_emoji_snapshot=record_type.emoji,
        data_kind_snapshot=record_type.data_kind,
        name=plan.name,
        note=payload.note if payload.note is not None else plan.note,
        occurred_on=occurred_on,
        next_due_date=next_due,
        weight_kg=payload.weight_kg,
        plan_id=plan.id,
        scheduled_due_date=scheduled_due,
        created_by=user.id,
    )
    session.add(row)
    if plan.recurrence_unit == "none" and payload.next_due_date_override is None:
        plan.active = False
        plan.next_due_date = None
    else:
        plan.next_due_date = next_due
    plan.last_notified_due_date = None
    plan.updated_at = datetime.now(UTC)
    session.add(plan)
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        existing = (await session.execute(existing_stmt)).scalar_one_or_none()
        if existing:
            return existing
        raise
    await session.refresh(row)
    return row


async def latest_weight(session: AsyncSession, family_id: UUID, pet_id: UUID) -> WeightPoint | None:
    stmt = (
        select(PetRecord)
        .where(
            PetRecord.family_id == family_id,
            PetRecord.pet_id == pet_id,
            PetRecord.data_kind_snapshot == "weight",
            PetRecord.weight_kg.is_not(None),
        )
        .order_by(PetRecord.occurred_on.desc(), PetRecord.created_at.desc())
        .limit(1)
    )
    row = (await session.execute(stmt)).scalars().first()
    if row is None or row.weight_kg is None:
        return None
    return WeightPoint(record_id=row.id, occurred_on=row.occurred_on, weight_kg=row.weight_kg)


async def weight_trend(
    session: AsyncSession, family_id: UUID, pet_id: UUID, limit: int = 30
) -> list[WeightPoint]:
    stmt = (
        select(PetRecord)
        .where(
            PetRecord.family_id == family_id,
            PetRecord.pet_id == pet_id,
            PetRecord.data_kind_snapshot == "weight",
            PetRecord.weight_kg.is_not(None),
        )
        .order_by(PetRecord.occurred_on.desc(), PetRecord.created_at.desc())
        .limit(limit)
    )
    rows = list((await session.execute(stmt)).scalars().all())
    rows.reverse()
    return [
        WeightPoint(record_id=row.id, occurred_on=row.occurred_on, weight_kg=row.weight_kg)
        for row in rows
        if row.weight_kg is not None
    ]


async def pet_list(session: AsyncSession, family_id: UUID, user: User) -> list[PetListItem]:
    await require_membership(session, user.id, family_id)
    pets = list(
        (
            await session.execute(
                select(Pet)
                .where(Pet.family_id == family_id, Pet.archived_at.is_(None))
                .order_by(Pet.created_at, Pet.id)
            )
        )
        .scalars()
        .all()
    )
    if not pets:
        return []
    pet_ids = [pet.id for pet in pets]
    plans = list(
        (
            await session.execute(
                select(PetCarePlan).where(
                    PetCarePlan.family_id == family_id,
                    PetCarePlan.pet_id.in_(pet_ids),
                    PetCarePlan.active.is_(True),
                    PetCarePlan.next_due_date.is_not(None),
                )
            )
        )
        .scalars()
        .all()
    )
    best_by_pet: dict[UUID, PetCarePlan] = {}
    for plan in plans:
        current = best_by_pet.get(plan.pet_id)
        if current is None or (plan.next_due_date or date.max) < (
            current.next_due_date or date.max
        ):
            best_by_pet[plan.pet_id] = plan
    type_map = await _type_map(session, family_id, {p.record_type_id for p in plans})
    items = [
        PetListItem(
            pet=to_pet_read(pet),
            next_plan=(
                plan_read(best_by_pet[pet.id], type_map[best_by_pet[pet.id].record_type_id])
                if pet.id in best_by_pet
                else None
            ),
            latest_weight=await latest_weight(session, family_id, pet.id),
        )
        for pet in pets
    ]
    return sorted(
        items,
        key=lambda item: (
            item.next_plan is None,
            item.next_plan.next_due_date if item.next_plan else date.max,
            item.pet.created_at,
        ),
    )


async def dashboard(
    session: AsyncSession, family_id: UUID, pet_id: UUID, user: User
) -> PetDashboard:
    await require_membership(session, user.id, family_id)
    pet = await load_active_pet(session, family_id, pet_id)
    plans, types = await list_plans(session, family_id, pet_id, user, active=True)
    today = date.today()
    today_rows = [p for p in plans if p.next_due_date and p.next_due_date <= today]
    upcoming_rows = [p for p in plans if p.next_due_date and p.next_due_date > today]
    records, cursor, _total = await record_page(session, family_id, pet_id, user, limit=20)
    return PetDashboard(
        pet=to_pet_read(pet),
        today_plans=[plan_read(p, types[p.record_type_id], today) for p in today_rows],
        upcoming_plans=[plan_read(p, types[p.record_type_id], today) for p in upcoming_rows],
        latest_weight=await latest_weight(session, family_id, pet_id),
        weight_trend=await weight_trend(session, family_id, pet_id),
        records=records,
        records_cursor=cursor,
    )


async def preview_hook(
    session: AsyncSession,
    ip: InstalledPlugin,
    _viewer_id: UUID | None = None,
) -> PluginPreview:
    family_id = ip.family_id
    pets = list(
        (
            await session.execute(
                select(Pet).where(Pet.family_id == family_id, Pet.archived_at.is_(None))
            )
        )
        .scalars()
        .all()
    )
    if not pets:
        return PluginPreview(
            primary="还没有宠物",
            secondary="添加一位毛孩子",
            color_token="pet",
            emoji="🐾",
        )
    pet_by_id = {pet.id: pet for pet in pets}
    plan = (
        (
            await session.execute(
                select(PetCarePlan)
                .where(
                    PetCarePlan.family_id == family_id,
                    PetCarePlan.pet_id.in_(pet_by_id),
                    PetCarePlan.active.is_(True),
                    PetCarePlan.next_due_date.is_not(None),
                )
                .order_by(PetCarePlan.next_due_date, PetCarePlan.created_at)
                .limit(1)
            )
        )
        .scalars()
        .first()
    )
    if plan and plan.next_due_date:
        pet = pet_by_id[plan.pet_id]
        days = (plan.next_due_date - date.today()).days
        if days < 0:
            secondary = f"已逾期 {-days} 天"
            tone = "danger"
        elif days == 0:
            secondary = "今天到期"
            tone = "warning"
        else:
            secondary = f"{days} 天后"
            tone = None
        return PluginPreview(
            primary=f"{pet.name} · {plan.name}",
            secondary=secondary,
            secondary_tone=tone,  # type: ignore[arg-type]
            color_token="pet",
            emoji=pet.emoji or "🐾",
        )
    latest = (
        (
            await session.execute(
                select(PetRecord)
                .where(
                    PetRecord.family_id == family_id,
                    PetRecord.pet_id.in_(pet_by_id),
                    PetRecord.data_kind_snapshot == "weight",
                    PetRecord.weight_kg.is_not(None),
                )
                .order_by(PetRecord.occurred_on.desc(), PetRecord.created_at.desc())
                .limit(1)
            )
        )
        .scalars()
        .first()
    )
    return PluginPreview(
        primary=f"{len(pets)} 只宠物",
        secondary=(f"最近体重 {latest.weight_kg.normalize()} kg" if latest else "今天都照顾好啦"),
        color_token="pet",
        emoji=pets[0].emoji or "🐾",
    )
