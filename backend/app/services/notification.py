"""Notification business logic — list/count/mark + domain notifier helpers.

The domain notifier functions (`notify_member_joined`, etc.) deliberately do
NOT commit. They `session.add(...)` and rely on the caller — usually a wider
business transaction — to commit. This keeps notification emission atomic
with the event that triggered it.
"""

from collections.abc import Sequence
from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import func, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.errors import AppError, ErrorCode
from app.models.family import Family
from app.models.membership import Membership
from app.models.notification import Notification
from app.models.user import User

DEFAULT_LIMIT = 50
MAX_LIMIT = 100


# ---- Read-side queries -----------------------------------------------------


async def count_unread(session: AsyncSession, user_id: UUID) -> int:
    stmt = (
        select(func.count())
        .select_from(Notification)
        .where(
            Notification.user_id == user_id,
            Notification.read_at.is_(None),
        )
    )
    return int((await session.execute(stmt)).scalar_one())


async def list_for_user(
    session: AsyncSession,
    user_id: UUID,
    limit: int = DEFAULT_LIMIT,
) -> list[Notification]:
    """Newest-first. Hard-capped at MAX_LIMIT until we add cursor pagination."""
    limit = max(1, min(limit, MAX_LIMIT))
    stmt = (
        select(Notification)
        .where(Notification.user_id == user_id)
        .order_by(Notification.created_at.desc())
        .limit(limit)
    )
    return list((await session.execute(stmt)).scalars().all())


async def mark_read(
    session: AsyncSession,
    notification_id: UUID,
    user_id: UUID,
) -> Notification:
    notif = await session.get(Notification, notification_id)
    # Hide existence from non-owners — same 404 whether the row doesn't exist
    # or belongs to someone else.
    if notif is None or notif.user_id != user_id:
        raise AppError(ErrorCode.NOT_FOUND, "通知不存在", status_code=404)
    if notif.read_at is None:
        notif.read_at = datetime.now(UTC)
        session.add(notif)
        await session.commit()
        await session.refresh(notif)
    return notif


async def mark_all_read(session: AsyncSession, user_id: UUID) -> int:
    """Mark all unread notifications as read. Returns number affected."""
    stmt = (
        update(Notification)
        .where(
            Notification.user_id == user_id,
            Notification.read_at.is_(None),
        )
        .values(read_at=datetime.now(UTC))
    )
    result = await session.execute(stmt)
    await session.commit()
    return int(result.rowcount or 0)


# ---- Domain notifier helpers (called from inside other services) -----------


async def _other_active_member_ids(
    session: AsyncSession,
    family_id: UUID,
    excluding_user_id: UUID,
) -> list[UUID]:
    stmt = select(Membership.user_id).where(
        Membership.family_id == family_id,
        Membership.user_id != excluding_user_id,
        Membership.status == "active",
    )
    return list((await session.execute(stmt)).scalars().all())


async def notify_member_joined(
    session: AsyncSession,
    *,
    family: Family,
    joining_user: User,
) -> None:
    """Tell every existing member that someone new joined the family.

    Caller's transaction commits these inserts. Excludes the joining user
    so they don't get pinged about their own action.
    """
    recipients = await _other_active_member_ids(session, family.id, joining_user.id)
    _add_for_recipients(
        session,
        recipients=recipients,
        notification_type="member_joined",
        family_id=family.id,
        title=f"{joining_user.display_name}加入了「{family.name}」",
        body="现在你们可以一起记录生活了 🎉",
        icon_emoji="👋",
        deeplink=f"wo://family/{family.id}/members",
    )


def _add_for_recipients(
    session: AsyncSession,
    *,
    recipients: Sequence[UUID],
    notification_type: str,
    family_id: UUID | None,
    title: str,
    body: str,
    icon_emoji: str = "🔔",
    deeplink: str | None = None,
) -> None:
    for uid in recipients:
        session.add(
            Notification(
                user_id=uid,
                type=notification_type,
                family_id=family_id,
                title=title,
                body=body,
                icon_emoji=icon_emoji,
                deeplink=deeplink,
            )
        )
