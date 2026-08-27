"""HTTP routes for 宠物日常."""

import logging
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, File, Query, UploadFile
from sqlalchemy import func
from sqlmodel import select
from starlette.responses import RedirectResponse, Response

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.ids import new_uuid7
from app.core.images import validate_image
from app.core.permissions import require_membership
from app.core.response import ApiResponse, Meta, ok
from app.core.storage import PresignableStorage, storage
from app.plugins.pet import service
from app.plugins.pet.models import (
    AttachmentRead,
    CarePlanCreate,
    CarePlanRead,
    CarePlanUpdate,
    PetDashboard,
    PetListItem,
    PetRecord,
    PetRecordAttachment,
    PlanCompletionCreate,
    RecordCreate,
    RecordRead,
    RecordTypeCreate,
    RecordTypeRead,
    RecordTypeReorder,
    RecordTypeUpdate,
    RecordUpdate,
    WeightPoint,
)
from app.services.membership import member_info_map

router = APIRouter(
    prefix="/families/{family_id}/plugins/pet",
    tags=["pet"],
)
logger = logging.getLogger(__name__)

MAX_ATTACHMENTS_PER_RECORD = 10
ALLOWED_PDF_TYPE = "application/pdf"


async def _delete_blob_best_effort(key: str, *, reason: str) -> None:
    try:
        await storage.delete(key)
    except Exception:  # noqa: BLE001
        logger.exception("pet attachment blob cleanup failed: %s (%s)", key, reason)


@router.get("/record-types", response_model=ApiResponse[list[RecordTypeRead]])
async def list_record_types(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    include_archived: bool = False,
) -> ApiResponse[list[RecordTypeRead]]:
    rows = await service.list_record_types(
        session, family_id, current_user, include_archived=include_archived
    )
    return ok([service.type_read(row) for row in rows])


@router.post("/record-types", response_model=ApiResponse[RecordTypeRead], status_code=201)
async def create_record_type(
    family_id: UUID,
    payload: RecordTypeCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RecordTypeRead]:
    row = await service.create_record_type(session, family_id, payload, current_user)
    return ok(service.type_read(row))


@router.put("/record-types/order", response_model=ApiResponse[list[RecordTypeRead]])
async def reorder_record_types(
    family_id: UUID,
    payload: RecordTypeReorder,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[RecordTypeRead]]:
    rows = await service.reorder_record_types(session, family_id, payload.ids, current_user)
    return ok([service.type_read(row) for row in rows])


@router.patch("/record-types/{type_id}", response_model=ApiResponse[RecordTypeRead])
async def update_record_type(
    family_id: UUID,
    type_id: UUID,
    payload: RecordTypeUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RecordTypeRead]:
    row = await service.update_record_type(session, family_id, type_id, payload, current_user)
    return ok(service.type_read(row))


@router.get("/pets", response_model=ApiResponse[list[PetListItem]])
async def list_pets(
    family_id: UUID, session: SessionDep, current_user: CurrentUserDep
) -> ApiResponse[list[PetListItem]]:
    return ok(await service.pet_list(session, family_id, current_user))


@router.get("/pets/{pet_id}", response_model=ApiResponse[PetDashboard])
async def get_dashboard(
    family_id: UUID,
    pet_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[PetDashboard]:
    return ok(await service.dashboard(session, family_id, pet_id, current_user))


@router.get("/pets/{pet_id}/plans", response_model=ApiResponse[list[CarePlanRead]])
async def list_plans(
    family_id: UUID,
    pet_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    active: bool | None = None,
) -> ApiResponse[list[CarePlanRead]]:
    rows, types = await service.list_plans(session, family_id, pet_id, current_user, active=active)
    return ok([service.plan_read(row, types[row.record_type_id]) for row in rows])


@router.post("/pets/{pet_id}/plans", response_model=ApiResponse[CarePlanRead], status_code=201)
async def create_plan(
    family_id: UUID,
    pet_id: UUID,
    payload: CarePlanCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[CarePlanRead]:
    row, record_type = await service.create_plan(session, family_id, pet_id, payload, current_user)
    return ok(service.plan_read(row, record_type))


@router.patch("/pets/{pet_id}/plans/{plan_id}", response_model=ApiResponse[CarePlanRead])
async def update_plan(
    family_id: UUID,
    pet_id: UUID,
    plan_id: UUID,
    payload: CarePlanUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[CarePlanRead]:
    row, record_type = await service.update_plan(
        session, family_id, pet_id, plan_id, payload, current_user
    )
    return ok(service.plan_read(row, record_type))


@router.delete("/pets/{pet_id}/plans/{plan_id}", response_model=ApiResponse[dict])
async def delete_plan(
    family_id: UUID,
    pet_id: UUID,
    plan_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await service.delete_plan(session, family_id, pet_id, plan_id, current_user)
    return ok({"deleted": str(plan_id)})


@router.post(
    "/pets/{pet_id}/plans/{plan_id}/completions",
    response_model=ApiResponse[RecordRead],
    status_code=201,
)
async def complete_plan(
    family_id: UUID,
    pet_id: UUID,
    plan_id: UUID,
    payload: PlanCompletionCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RecordRead]:
    row = await service.complete_plan(session, family_id, pet_id, plan_id, payload, current_user)
    info = await member_info_map(session, family_id)
    return ok(service.record_read(row, info))


@router.get("/pets/{pet_id}/records", response_model=ApiResponse[list[RecordRead]])
async def list_records(
    family_id: UUID,
    pet_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    cursor: str | None = None,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
) -> ApiResponse[list[RecordRead]]:
    rows, next_cursor, total = await service.record_page(
        session,
        family_id,
        pet_id,
        current_user,
        cursor=cursor,
        limit=limit,
    )
    return ok(rows, meta=Meta(total=total, cursor=next_cursor, limit=limit))


@router.post("/pets/{pet_id}/records", response_model=ApiResponse[RecordRead], status_code=201)
async def create_record(
    family_id: UUID,
    pet_id: UUID,
    payload: RecordCreate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RecordRead]:
    row = await service.create_record(session, family_id, pet_id, payload, current_user)
    info = await member_info_map(session, family_id)
    return ok(service.record_read(row, info))


@router.patch("/pets/{pet_id}/records/{record_id}", response_model=ApiResponse[RecordRead])
async def update_record(
    family_id: UUID,
    pet_id: UUID,
    record_id: UUID,
    payload: RecordUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[RecordRead]:
    row = await service.update_record(session, family_id, pet_id, record_id, payload, current_user)
    attachments = list(
        (
            await session.execute(
                select(PetRecordAttachment)
                .where(PetRecordAttachment.record_id == row.id)
                .order_by(PetRecordAttachment.sort_order)
            )
        )
        .scalars()
        .all()
    )
    info = await member_info_map(session, family_id)
    return ok(service.record_read(row, info, attachments))


@router.delete("/pets/{pet_id}/records/{record_id}", response_model=ApiResponse[dict])
async def delete_record(
    family_id: UUID,
    pet_id: UUID,
    record_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    keys = await service.delete_record(session, family_id, pet_id, record_id, current_user)
    for key in keys:
        await _delete_blob_best_effort(key, reason="record deleted")
    return ok({"deleted": str(record_id)})


async def _record_for_attachment(
    session: SessionDep, family_id: UUID, record_id: UUID
) -> PetRecord:
    row = await session.get(PetRecord, record_id)
    if row is None or row.family_id != family_id:
        raise AppError(ErrorCode.NOT_FOUND, "健康记录不存在", status_code=404)
    return row


def _attachment_storage_key(family_id: UUID, record_id: UUID, attachment_id: UUID, ext: str) -> str:
    return f"pet/{family_id}/records/{record_id}/{attachment_id}.{ext}"


@router.post(
    "/records/{record_id}/attachments",
    response_model=ApiResponse[AttachmentRead],
    status_code=201,
)
async def upload_attachment(
    family_id: UUID,
    record_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
    file: Annotated[UploadFile, File(...)],
) -> ApiResponse[AttachmentRead]:
    membership = await require_membership(session, current_user.id, family_id)
    record = await _record_for_attachment(session, family_id, record_id)
    if membership.role not in ("owner", "admin") and record.created_by != current_user.id:
        raise AppError(ErrorCode.FORBIDDEN, "只能给自己创建的记录添加附件", status_code=403)
    count = int(
        (
            await session.execute(
                select(func.count())
                .select_from(PetRecordAttachment)
                .where(PetRecordAttachment.record_id == record.id)
            )
        ).scalar_one()
    )
    if count >= MAX_ATTACHMENTS_PER_RECORD:
        raise AppError(ErrorCode.VALIDATION_ERROR, "单条记录附件数量已达上限", status_code=400)
    cap = settings.max_upload_bytes
    content = await file.read(cap + 1)
    if len(content) > cap:
        raise AppError(ErrorCode.FILE_TOO_LARGE, "附件超过大小上限", status_code=413)
    if not content:
        raise AppError(ErrorCode.VALIDATION_ERROR, "附件为空", status_code=400)
    if content.startswith(b"%PDF-"):
        content_type, ext = ALLOWED_PDF_TYPE, "pdf"
    else:
        content_type, ext, _w, _h = validate_image(content)
    attachment_id = new_uuid7()
    key = _attachment_storage_key(family_id, record.id, attachment_id, ext)
    await storage.put(key, content, content_type)
    row = PetRecordAttachment(
        id=attachment_id,
        family_id=family_id,
        record_id=record.id,
        original_filename=(file.filename or f"attachment.{ext}")[:255],
        storage_key=key,
        content_type=content_type,
        size_bytes=len(content),
        sort_order=count,
        created_by=current_user.id,
    )
    session.add(row)
    try:
        await session.commit()
        await session.refresh(row)
    except Exception:
        await _delete_blob_best_effort(key, reason="database write failed")
        raise
    return ok(service.attachment_read(row))


async def _load_attachment(
    session: SessionDep, family_id: UUID, record_id: UUID, attachment_id: UUID
) -> PetRecordAttachment:
    row = await session.get(PetRecordAttachment, attachment_id)
    if row is None or row.family_id != family_id or row.record_id != record_id:
        raise AppError(ErrorCode.NOT_FOUND, "附件不存在", status_code=404)
    return row


@router.get("/records/{record_id}/attachments/{attachment_id}")
async def get_attachment(
    family_id: UUID,
    record_id: UUID,
    attachment_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> Response:
    await require_membership(session, current_user.id, family_id)
    await _record_for_attachment(session, family_id, record_id)
    row = await _load_attachment(session, family_id, record_id, attachment_id)
    if isinstance(storage, PresignableStorage):
        url = await storage.presigned_get_url(row.storage_key, ttl_seconds=3600)
        return RedirectResponse(url, status_code=302)
    try:
        data = await storage.get(row.storage_key)
    except FileNotFoundError as exc:
        raise AppError(ErrorCode.NOT_FOUND, "附件文件不存在", status_code=404) from exc
    return Response(content=data, media_type=row.content_type)


@router.delete("/records/{record_id}/attachments/{attachment_id}", response_model=ApiResponse[dict])
async def delete_attachment(
    family_id: UUID,
    record_id: UUID,
    attachment_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    membership = await require_membership(session, current_user.id, family_id)
    record = await _record_for_attachment(session, family_id, record_id)
    if membership.role not in ("owner", "admin") and record.created_by != current_user.id:
        raise AppError(ErrorCode.FORBIDDEN, "只能删除自己记录的附件", status_code=403)
    row = await _load_attachment(session, family_id, record_id, attachment_id)
    key = row.storage_key
    await session.delete(row)
    await session.commit()
    await _delete_blob_best_effort(key, reason="attachment deleted")
    return ok({"deleted": str(attachment_id)})


@router.get("/pets/{pet_id}/weights", response_model=ApiResponse[list[WeightPoint]])
async def get_weight_trend(
    family_id: UUID,
    pet_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[WeightPoint]]:
    await require_membership(session, current_user.id, family_id)
    await service.load_active_pet(session, family_id, pet_id)
    return ok(await service.weight_trend(session, family_id, pet_id))
