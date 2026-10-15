"""仅用合成微信身份；所有上游网络由依赖替身隔离，绝不调用真实微信。"""

import asyncio
import logging
import uuid

import httpx
import pytest
from pydantic import SecretStr
from sqlalchemy import func
from sqlmodel import select

from app.api.v1.routes import wechat as routes
from app.core.config import settings
from app.core.database import async_session_maker
from app.core.errors import AppError
from app.core.password import verify_password
from app.main import app
from app.models.user import User
from app.models.wechat_identity import WechatIdentity
from app.services import wechat
from app.services.session import resolve_user_id


@pytest.fixture(autouse=True)
def reset_wechat_limits():
    routes._ip_limiter.reset()
    routes._identity_limiter.reset()


@pytest.fixture
def identity(monkeypatch):
    verified = wechat.VerifiedWechatIdentity("test-only-app", f"synthetic-{uuid.uuid4().hex}")

    async def fake_exchange(code):
        assert code == "test-only-code"
        return verified

    monkeypatch.setattr(wechat, "exchange_code", fake_exchange)
    return verified


async def request(client, endpoint, **extra):
    return await client.post(
        f"/api/v1/auth/wechat/{endpoint}", json={"code": "test-only-code", **extra}
    )


async def test_missing_credentials_fails_closed(monkeypatch):
    monkeypatch.setattr(settings, "wechat_app_id", "")
    monkeypatch.setattr(settings, "wechat_app_secret", SecretStr(""))
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await request(client, "login")
    assert response.status_code == 503
    assert response.headers["Cache-Control"] == "no-store"
    assert "token" not in response.json()["error"]["message"]


@pytest.mark.parametrize(
    "payload",
    [
        {"errcode": 40029, "errmsg": "secret upstream error"},
        {},
        {"openid": "synthetic"},
        {"openid": [], "session_key": "private"},
        [],
    ],
)
async def test_exchange_rejects_invalid_upstream(monkeypatch, payload):
    monkeypatch.setattr(settings, "wechat_app_id", "test-only-app")
    monkeypatch.setattr(settings, "wechat_app_secret", SecretStr("test-only-secret"))
    real_client = httpx.AsyncClient
    transport = httpx.MockTransport(lambda req: httpx.Response(200, json=payload))
    monkeypatch.setattr(wechat.httpx, "AsyncClient", lambda **kw: real_client(transport=transport))
    with pytest.raises(AppError) as error:
        await wechat.exchange_code("test-only-code")
    assert error.value.status_code == 401
    assert "secret" not in error.value.message


async def test_exchange_does_not_return_keys_or_log_secrets(monkeypatch, caplog):
    monkeypatch.setattr(settings, "wechat_app_id", "test-only-app")
    monkeypatch.setattr(settings, "wechat_app_secret", SecretStr("test-only-secret"))

    def respond(req):
        assert req.url.scheme == "https"
        assert req.url.host == "api.weixin.qq.com"
        assert req.url.params["js_code"] == "test-only-code"
        assert req.url.params["secret"] == "test-only-secret"
        return httpx.Response(200, json={"openid": "synthetic", "session_key": "private-key"})

    real_client = httpx.AsyncClient
    transport = httpx.MockTransport(respond)
    monkeypatch.setattr(wechat.httpx, "AsyncClient", lambda **kw: real_client(transport=transport))
    with caplog.at_level(logging.INFO, logger="httpx"):
        result = await wechat.exchange_code("test-only-code")
    assert result == wechat.VerifiedWechatIdentity("test-only-app", "synthetic")
    assert "private-key" not in repr(result)
    assert "test-only-secret" not in caplog.text
    assert "test-only-code" not in caplog.text


async def test_exchange_timeout_is_sanitized(monkeypatch):
    monkeypatch.setattr(settings, "wechat_app_id", "test-only-app")
    monkeypatch.setattr(settings, "wechat_app_secret", SecretStr("test-only-secret"))

    def respond(req):
        raise httpx.ConnectTimeout("test-only-secret", request=req)

    real_client = httpx.AsyncClient
    transport = httpx.MockTransport(respond)
    monkeypatch.setattr(wechat.httpx, "AsyncClient", lambda **kw: real_client(transport=transport))
    with pytest.raises(AppError) as error:
        await wechat.exchange_code("test-only-code")
    assert error.value.status_code == 502
    assert "test-only-secret" not in str(error.value)


async def test_unknown_identity_requires_explicit_registration(client, identity):
    response = await request(client, "login")
    assert response.status_code == 200
    assert response.json()["data"] == {"registration_required": True}
    assert response.headers["Cache-Control"] == "no-store"


async def test_register_reuses_real_sessions_and_preserves_recovery(client, identity):
    response = await request(client, "register", password="test-password", display_name="新成员")
    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"
    data = response.json()["data"]
    assert data["is_new"] is True
    assert data["recovery_code"]
    uid = uuid.UUID(data["user"]["id"])
    async with async_session_maker() as session:
        user = await session.get(User, uid)
        assert user.phone is None
        assert verify_password("test-password", user.password_hash)
        assert data["recovery_code"] != user.recovery_code_hash
        assert await resolve_user_id(session, data["token"]) == uid
    login = await request(client, "login")
    assert login.json()["data"]["user"]["id"] == str(uid)
    assert login.json()["data"]["is_new"] is False
    auth = {"Authorization": f"Bearer {data['token']}"}
    assert (await client.get("/api/v1/me/bootstrap", headers=auth)).status_code == 200
    await client.post("/api/v1/auth/logout-all", headers=auth)
    assert (await client.get("/api/v1/me/bootstrap", headers=auth)).status_code == 401


async def test_bind_requires_existing_phone_password(client, identity):
    phone = f"139{uuid.uuid4().int % 100000000:08d}"
    original = (
        await client.post(
            "/api/v1/auth/login", json={"phone": phone, "password": "original-password"}
        )
    ).json()["data"]
    bad = await request(client, "bind", phone=phone, password="wrong-password")
    assert bad.status_code == 401
    assert bad.headers["Cache-Control"] == "no-store"
    assert (await request(client, "login")).json()["data"] == {"registration_required": True}
    bound = await request(client, "bind", phone=phone, password="original-password")
    assert bound.status_code == 200
    assert bound.json()["data"]["user"]["id"] == original["user"]["id"]
    assert (await request(client, "login")).json()["data"]["user"]["id"] == original["user"]["id"]


async def test_bind_never_creates_a_phone_account(client, identity):
    phone = f"139{uuid.uuid4().int % 100000000:08d}"
    response = await request(client, "bind", phone=phone, password="test-password")
    assert response.status_code == 401
    async with async_session_maker() as session:
        assert (
            await session.execute(select(User).where(User.phone == phone))
        ).scalar_one_or_none() is None


async def test_mapping_never_merges_users(client, identity):
    registered = (await request(client, "register", password="test-password")).json()["data"]
    phone = f"139{uuid.uuid4().int % 100000000:08d}"
    await client.post("/api/v1/auth/login", json={"phone": phone, "password": "test-password"})
    response = await request(client, "bind", phone=phone, password="test-password")
    assert response.status_code == 409
    login = await request(client, "login")
    assert login.json()["data"]["user"]["id"] == registered["user"]["id"]


async def test_recovery_revokes_sessions_and_is_single_use(client, identity):
    data = (await request(client, "register", password="test-password")).json()["data"]
    payload = {"recovery_code": data["recovery_code"], "new_password": "changed-password"}
    reset = await request(client, "reset-password", **payload)
    assert reset.status_code == 200
    async with async_session_maker() as session:
        assert await resolve_user_id(session, data["token"]) is None
        user = await session.get(User, uuid.UUID(data["user"]["id"]))
        assert verify_password("changed-password", user.password_hash)
    assert (await request(client, "reset-password", **payload)).status_code == 401


async def test_parallel_registration_rolls_back_orphan_users(client, identity):
    responses = await asyncio.gather(
        request(client, "register", password="test-password", display_name=identity.openid[:24]),
        request(client, "register", password="test-password", display_name=identity.openid[:24]),
    )
    assert sorted(response.status_code for response in responses) == [200, 409]
    async with async_session_maker() as session:
        assert (
            await session.execute(
                select(func.count())
                .select_from(WechatIdentity)
                .where(
                    WechatIdentity.app_id == identity.app_id,
                    WechatIdentity.openid == identity.openid,
                )
            )
        ).scalar_one() == 1
        assert (
            await session.execute(
                select(func.count())
                .select_from(User)
                .where(
                    User.display_name == identity.openid[:24],
                )
            )
        ).scalar_one() == 1


async def test_identity_rate_limit(client, identity):
    for _ in range(settings.login_rate_limit_per_phone_max):
        assert (await request(client, "login")).status_code == 200
    response = await request(client, "login")
    assert response.status_code == 429
    assert response.headers["Cache-Control"] == "no-store"


async def test_auth_validation_does_not_echo_secrets(identity):
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await request(client, "register", password="abcd", recovery_code="private-code")
    assert response.status_code == 422
    assert response.headers["Cache-Control"] == "no-store"
    assert "private-code" not in response.text
    assert "abcd" not in response.text


async def test_parallel_bind_never_joins_two_original_accounts(client, identity):
    phones = [f"139{uuid.uuid4().int % 100000000:08d}" for _ in range(2)]
    users = []
    for phone in phones:
        response = await client.post(
            "/api/v1/auth/login", json={"phone": phone, "password": "test-password"}
        )
        users.append(response.json()["data"]["user"]["id"])
    responses = await asyncio.gather(
        *[request(client, "bind", phone=phone, password="test-password") for phone in phones]
    )
    assert sorted(response.status_code for response in responses) == [200, 409]
    async with async_session_maker() as session:
        rows = (
            (
                await session.execute(
                    select(WechatIdentity).where(
                        WechatIdentity.app_id == identity.app_id,
                        WechatIdentity.openid == identity.openid,
                    )
                )
            )
            .scalars()
            .all()
        )
        assert len(rows) == 1
        assert str(rows[0].user_id) in users
        for user_id in users:
            assert await session.get(User, uuid.UUID(user_id)) is not None


async def test_openid_is_scoped_to_app_id(client, identity, monkeypatch):
    first = (await request(client, "register", password="test-password")).json()["data"]

    async def another_app(code):
        return wechat.VerifiedWechatIdentity("other-test-app", identity.openid)

    monkeypatch.setattr(wechat, "exchange_code", another_app)
    assert (await request(client, "login")).json()["data"] == {"registration_required": True}
    second = (await request(client, "register", password="test-password")).json()["data"]
    assert second["user"]["id"] != first["user"]["id"]


async def test_legacy_without_password_cannot_bind(client, identity):
    phone = f"139{uuid.uuid4().int % 100000000:08d}"
    async with async_session_maker() as session:
        user = User(phone=phone, username=f"legacy-{uuid.uuid4().hex[:20]}", display_name="旧用户")
        session.add(user)
        await session.commit()
        uid = user.id
    assert (await request(client, "bind", phone=phone, password="test-password")).status_code == 401
    async with async_session_maker() as session:
        assert (await session.get(User, uid)).password_hash is None
        assert await wechat.identity_row(session, identity) is None
