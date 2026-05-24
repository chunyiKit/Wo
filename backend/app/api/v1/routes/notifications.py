"""Notification endpoints — list, mark-one-read, mark-all-read.

Pagination is intentionally simple for now: newest first, capped at 100.
Cursor pagination lands when notification volume grows; see
`app.services.notification.MAX_LIMIT`.
"""

from uuid import UUID

from fastapi import APIRouter, Query
from pydantic import BaseModel

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.response import ApiResponse, ok
from app.models.notification import NotificationRead
from app.services import notification as notification_service

router = APIRouter(prefix="/notifications", tags=["notifications"])


class MarkAllReadResponse(BaseModel):
    marked: int


@router.get("", response_model=ApiResponse[list[NotificationRead]])
async def list_notifications(
    session: SessionDep,
    current_user: CurrentUserDep,
    limit: int = Query(default=50, ge=1, le=100),
) -> ApiResponse[list[NotificationRead]]:
    items = await notification_service.list_for_user(session, current_user.id, limit)
    return ok([NotificationRead.model_validate(n, from_attributes=True) for n in items])


@router.patch(
    "/{notification_id}/read",
    response_model=ApiResponse[NotificationRead],
)
async def mark_notification_read(
    notification_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[NotificationRead]:
    notif = await notification_service.mark_read(session, notification_id, current_user.id)
    return ok(NotificationRead.model_validate(notif, from_attributes=True))


@router.post("/read-all", response_model=ApiResponse[MarkAllReadResponse])
async def mark_all_notifications_read(
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[MarkAllReadResponse]:
    affected = await notification_service.mark_all_read(session, current_user.id)
    return ok(MarkAllReadResponse(marked=affected))
