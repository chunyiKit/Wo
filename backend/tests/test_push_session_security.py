"""推送只能送到有效会话，撤销与登记/出队的并发回归。"""

import asyncio
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlmodel import select

from app.core.database import async_session_maker
from app.models.auth_session import AuthSession
from app.models.device_token import DeviceToken
from app.models.family import Family
from app.models.notification import Notification
from app.models.push_outbox import PushOutbox
from app.plugins.chat.models import ChatMessage, ChatPushOutbox
from app.plugins.chat.push import dispatch_pending_chat
from app.services.auth import locked_user, revoke_all
from app.services.device_token import register_device, tokens_for_user
from app.services.push_dispatcher import dispatch_pending
from app.services.session import _hash_token, issue_session, revoke_session
from tests.test_account_security import account, bearer, enroll, reset
from tests.test_auth import PW


def rid():
    return f"test-{uuid.uuid4().hex}"


async def bind(client, token, registration_id=None):
    registration_id = registration_id or rid()
    response = await client.post(
        "/api/v1/devices/register",
        headers=bearer(token),
        json={"registration_id": registration_id, "platform": "android"},
    )
    assert response.status_code == 200
    return registration_id


async def audience(uid):
    async with async_session_maker() as session:
        return await tokens_for_user(session, uid)


async def stage(uid, kind):
    async with async_session_maker() as session:
        if kind == "notification":
            notif = Notification(user_id=uid, type="test_push", title="私密通知", body="私密正文")
            session.add(notif)
            await session.flush()
            row = PushOutbox(notification_id=notif.id)
        else:
            family = Family(name="推送隔离测试", emoji="🏡")
            session.add(family)
            await session.flush()
            message = ChatMessage(
                family_id=family.id,
                sender_id=uid,
                client_id=uuid.uuid4().hex,
                kind="text",
                body="私密聊天正文",
                sender_name="测试作者",
                sender_emoji="👤",
            )
            session.add(message)
            await session.flush()
            row = ChatPushOutbox(message_id=message.id, user_id=uid)
        session.add(row)
        await session.commit()
        return row.id


async def drain(kind, sender):
    async with async_session_maker() as session:
        dispatcher = dispatch_pending if kind == "notification" else dispatch_pending_chat
        return await dispatcher(session, sender, batch_size=10000)


@pytest.mark.parametrize("operation", ["all", "change", "reset"])
async def test_account_revocations_unbind_all_devices_and_only_this_user(client, operation):
    phone, token, uid = await account(client)
    async with async_session_maker() as session:
        other_session = await issue_session(session, uid, ttl_days=1)
    _, other_token, other_uid = await account(client)
    retired = {await bind(client, token), await bind(client, other_session)}
    survivor = await bind(client, other_token)
    async with async_session_maker() as session:
        session.add(DeviceToken(user_id=uid, registration_id=rid(), platform="android"))
        await session.commit()
    await stage(uid, "notification")
    await stage(uid, "chat")
    if operation == "all":
        response = await client.post("/api/v1/auth/logout-all", headers=bearer(token))
    elif operation == "change":
        response = await client.post(
            "/api/v1/auth/change-password",
            headers=bearer(token),
            json={"old_password": PW, "new_password": "new-password"},
        )
    else:
        code = (await enroll(client, token)).json()["data"]["recovery_code"]
        response = await reset(client, phone, code)
    assert response.status_code == 200
    async with async_session_maker() as session:
        assert (
            not (await session.execute(select(DeviceToken).where(DeviceToken.user_id == uid)))
            .scalars()
            .all()
        )
    sent = []

    async def sender(message):
        sent.extend(message.registration_ids)

    await drain("notification", sender)
    await drain("chat", sender)
    assert retired.isdisjoint(sent)
    assert await audience(other_uid) == [survivor]


async def test_current_logout_preserves_other_sessions_and_users(client):
    _, token, uid = await account(client)
    async with async_session_maker() as session:
        second = await issue_session(session, uid, ttl_days=1)
    _, third, other_uid = await account(client)
    retired = await bind(client, token)
    survivor = await bind(client, second)
    other_device = await bind(client, third)
    async with async_session_maker() as session:
        session.add(DeviceToken(user_id=uid, registration_id=rid(), platform="android"))
        await session.commit()
    assert (await client.post("/api/v1/auth/logout", headers=bearer(token))).status_code == 200
    assert await audience(uid) == [survivor]
    assert await audience(other_uid) == [other_device]
    await stage(uid, "notification")
    await stage(uid, "chat")
    sent = []

    async def sender(message):
        sent.extend(message.registration_ids)

    await drain("notification", sender)
    await drain("chat", sender)
    assert retired not in sent and survivor in sent


async def test_legacy_device_does_not_receive_until_rebound(client):
    _, token, uid = await account(client)
    legacy = rid()
    async with async_session_maker() as session:
        session.add(DeviceToken(user_id=uid, registration_id=legacy, platform="android"))
        await session.commit()
    assert await audience(uid) == []
    await bind(client, token, legacy)
    assert await audience(uid) == [legacy]
    async with async_session_maker() as session:
        device = (
            await session.execute(select(DeviceToken).where(DeviceToken.registration_id == legacy))
        ).scalar_one()
        auth = await session.get(AuthSession, device.session_id)
        assert auth.token_hash == _hash_token(token) and auth.user_id == uid


async def test_expired_session_never_receives_push_or_reregisters(client):
    _, token, uid = await account(client)
    registration_id = await bind(client, token)
    async with async_session_maker() as session:
        auth = (
            await session.execute(
                select(AuthSession).where(AuthSession.token_hash == _hash_token(token))
            )
        ).scalar_one()
        auth.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        session.add(auth)
        await session.commit()
    assert await audience(uid) == []
    response = await client.post(
        "/api/v1/devices/register",
        headers=bearer(token),
        json={"registration_id": registration_id, "platform": "android"},
    )
    assert response.status_code == 401


async def test_dev_identifier_cannot_bind_push_device(client):
    _, token, uid = await account(client)
    response = await client.post(
        "/api/v1/devices/register",
        headers={"X-User-Id": str(uid)},
        json={"registration_id": rid(), "platform": "android"},
    )
    assert response.status_code == 401
    assert await audience(uid) == []


@pytest.mark.parametrize("operation", ["current", "all"])
async def test_registration_waiting_for_revocation_cannot_rebind(client, operation):
    _, token, uid = await account(client)
    new_id = rid()
    async with async_session_maker() as session:
        await locked_user(session, uid, token)

        async def registering():
            async with async_session_maker() as waiter:
                await register_device(
                    waiter,
                    user_id=uid,
                    registration_id=new_id,
                    platform="android",
                    bearer_token=token,
                )

        waiting = asyncio.create_task(registering())
        await asyncio.sleep(0.05)
        assert not waiting.done()
        if operation == "current":
            await revoke_session(session, token)
        else:
            await revoke_all(session, uid)
            await session.commit()
        from app.core.errors import AppError

        with pytest.raises(AppError):
            await waiting
    assert await audience(uid) == []


@pytest.mark.parametrize("kind", ["notification", "chat"])
async def test_dispatch_waiting_on_revocation_does_not_send_queued_private_payload(client, kind):
    _, token, uid = await account(client)
    retired = await bind(client, token)
    await stage(uid, kind)
    sent = []

    async def sender(message):
        sent.extend(message.registration_ids)

    async with async_session_maker() as session:
        await locked_user(session, uid, token)
        pending = asyncio.create_task(drain(kind, sender))
        await asyncio.sleep(0.05)
        assert not pending.done()
        await revoke_all(session, uid)
        await session.commit()
        await pending
    assert retired not in sent


@pytest.mark.parametrize("kind", ["notification", "chat"])
async def test_revocation_waits_for_send_and_then_excludes_device(client, kind):
    _, token, uid = await account(client)
    retired = await bind(client, token)
    await stage(uid, kind)
    started, release = asyncio.Event(), asyncio.Event()

    async def sender(message):
        if retired in message.registration_ids:
            started.set()
            await release.wait()

    pending = asyncio.create_task(drain(kind, sender))
    await asyncio.wait_for(started.wait(), 3)
    logout = asyncio.create_task(client.post("/api/v1/auth/logout", headers=bearer(token)))
    await asyncio.sleep(0.05)
    assert not logout.done()
    release.set()
    await pending
    assert (await logout).status_code == 200
    await stage(uid, kind)
    sent = []

    async def after(message):
        sent.extend(message.registration_ids)

    await drain(kind, after)
    assert retired not in sent


@pytest.mark.parametrize("kind", ["notification", "chat"])
async def test_dispatchers_do_not_duplicate_same_intent(client, kind):
    _, token, uid = await account(client)
    target = await bind(client, token)
    await stage(uid, kind)
    deliveries = []

    async def sender(message):
        if target in message.registration_ids:
            deliveries.append(message)
            await asyncio.sleep(0.03)

    await asyncio.gather(drain(kind, sender), drain(kind, sender))
    assert len(deliveries) == 1


async def test_reassigned_device_survives_old_owner_logout_and_unregister(client):
    _, old_token, old_uid = await account(client)
    _, new_token, new_uid = await account(client)
    installation = await bind(client, old_token)
    await bind(client, new_token, installation)
    assert (
        await client.delete(f"/api/v1/devices/{installation}", headers=bearer(old_token))
    ).status_code == 200
    assert (
        await client.post("/api/v1/auth/logout-all", headers=bearer(old_token))
    ).status_code == 200
    assert await audience(old_uid) == []
    assert await audience(new_uid) == [installation]


async def test_new_session_binding_survives_old_session_unregistration(client):
    _, old_token, uid = await account(client)
    async with async_session_maker() as session:
        new_token = await issue_session(session, uid, ttl_days=1)
    installation = await bind(client, old_token)
    await bind(client, new_token, installation)
    assert (
        await client.delete(f"/api/v1/devices/{installation}", headers=bearer(old_token))
    ).status_code == 200
    assert (await client.post("/api/v1/auth/logout", headers=bearer(old_token))).status_code == 200
    assert await audience(uid) == [installation]


@pytest.mark.parametrize("kind", ["notification", "chat"])
async def test_device_reassignment_waits_for_old_private_send(client, kind):
    _, old_token, old_uid = await account(client)
    _, new_token, new_uid = await account(client)
    installation = await bind(client, old_token)
    await stage(old_uid, kind)
    started, release = asyncio.Event(), asyncio.Event()

    async def sender(message):
        if installation in message.registration_ids:
            started.set()
            await release.wait()

    dispatch = asyncio.create_task(drain(kind, sender))
    await asyncio.wait_for(started.wait(), 3)
    rebind = asyncio.create_task(bind(client, new_token, installation))
    await asyncio.sleep(0.05)
    assert not rebind.done()
    release.set()
    await dispatch
    await rebind
    assert await audience(old_uid) == []
    assert await audience(new_uid) == [installation]
    await stage(old_uid, kind)
    sent = []

    async def after(message):
        sent.extend(message.registration_ids)

    await drain(kind, after)
    assert installation not in sent
