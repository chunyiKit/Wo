"""Device token registration — upsert by globally-unique registration id."""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.device_token import DeviceToken


async def register_device(
    session: AsyncSession,
    *,
    user_id: UUID,
    registration_id: str,
    platform: str,
) -> DeviceToken:
    """Idempotent upsert keyed on `registration_id`.

    Re-registering an existing registration id reassigns it to the current user
    — this covers "logout, then log in as someone else on the same device", so a
    stale owner never keeps receiving the new user's pushes.
    """
    existing = (
        await session.execute(
            select(DeviceToken).where(DeviceToken.registration_id == registration_id)
        )
    ).scalar_one_or_none()
    now = datetime.now(UTC)
    if existing is not None:
        existing.user_id = user_id
        existing.platform = platform
        existing.updated_at = now
        session.add(existing)
        await session.commit()
        await session.refresh(existing)
        return existing

    token = DeviceToken(user_id=user_id, registration_id=registration_id, platform=platform)
    session.add(token)
    await session.commit()
    await session.refresh(token)
    return token


async def unregister_device(
    session: AsyncSession,
    *,
    registration_id: str,
    user_id: UUID,
) -> None:
    """Remove a device token (call on logout). Scoped to the owner so one user
    can't unregister another's device. No-op if the row is absent."""
    await session.execute(
        delete(DeviceToken).where(
            DeviceToken.registration_id == registration_id,
            DeviceToken.user_id == user_id,
        )
    )
    await session.commit()


async def tokens_for_user(session: AsyncSession, user_id: UUID) -> list[str]:
    """All registration ids for a user — the audience of a push to that user."""
    stmt = select(DeviceToken.registration_id).where(DeviceToken.user_id == user_id)
    return list((await session.execute(stmt)).scalars().all())
