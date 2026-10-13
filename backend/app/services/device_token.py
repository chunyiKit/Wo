"""Push registration bound to a live bearer session, with serialized delivery."""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import delete, func
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.auth_session import AuthSession
from app.models.device_token import DeviceToken
from app.models.user import User
from app.services.auth import locked_user
from app.services.session import _hash_token


async def register_device(
    session: AsyncSession,
    *,
    user_id: UUID,
    registration_id: str,
    platform: str,
    bearer_token: str,
) -> DeviceToken:
    # Do not trust an identifier/shim or a session validated before waiting.
    await locked_user(session, user_id, bearer_token)
    auth_session_id = (
        await session.execute(
            select(AuthSession.id).where(
                AuthSession.user_id == user_id,
                AuthSession.token_hash == _hash_token(bearer_token),
            )
        )
    ).scalar_one()
    now = datetime.now(UTC)
    stmt = (
        insert(DeviceToken)
        .values(
            user_id=user_id,
            session_id=auth_session_id,
            registration_id=registration_id,
            platform=platform,
            created_at=now,
            updated_at=now,
        )
        .on_conflict_do_update(
            index_elements=["registration_id"],
            set_={
                "user_id": user_id,
                "session_id": auth_session_id,
                "platform": platform,
                "updated_at": now,
            },
        )
        .returning(DeviceToken)
    )
    token = (await session.execute(stmt.execution_options(populate_existing=True))).scalar_one()
    await session.commit()
    return token


async def unregister_device(
    session: AsyncSession,
    *,
    registration_id: str,
    user_id: UUID,
    bearer_token: str,
) -> None:
    await locked_user(session, user_id, bearer_token)
    # A delayed old client must not remove the same installation after it was
    # rebound to a newer session, even when the account itself is unchanged.
    auth_session_id = (
        await session.execute(
            select(AuthSession.id).where(
                AuthSession.user_id == user_id,
                AuthSession.token_hash == _hash_token(bearer_token),
            )
        )
    ).scalar_one()
    await session.execute(
        delete(DeviceToken).where(
            DeviceToken.registration_id == registration_id,
            DeviceToken.user_id == user_id,
            DeviceToken.session_id == auth_session_id,
        )
    )
    await session.commit()


async def tokens_for_user(session: AsyncSession, user_id: UUID) -> list[str]:
    """Hold recipient and device locks until the caller finishes sending/commits.

    Serializes sends with revocation and installation reassignment. Dispatchers
    must claim the outbox AFTER this lock, and commit per recipient/intent.
    Unbound historical devices, expired tokens and locked accounts are excluded.
    """
    await session.execute(select(User.id).where(User.id == user_id).with_for_update())
    stmt = (
        select(DeviceToken.registration_id)
        .join(
            AuthSession,
            AuthSession.id == DeviceToken.session_id,
        )
        .join(User, User.id == DeviceToken.user_id)
        .where(
            DeviceToken.user_id == user_id,
            AuthSession.user_id == user_id,
            AuthSession.expires_at > func.clock_timestamp(),
            User.password_hash.is_not(None),
            User.password_hash != "",
        )
        .with_for_update(of=DeviceToken)
    )
    return list((await session.execute(stmt)).scalars().all())
