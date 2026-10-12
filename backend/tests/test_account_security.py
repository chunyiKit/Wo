"""真实 Bearer + 隔离数据库的找回、撤销、并发回归。"""

import asyncio
from datetime import UTC, datetime, timedelta
from uuid import UUID

import pytest
from sqlmodel import select

from app.core.database import async_session_maker
from app.models.auth_session import AuthSession
from app.models.user import User
from app.services.session import _hash_token, issue_session
from tests.test_auth import PW, _login, _random_phone


@pytest.fixture(autouse=True)
def generous_limits(monkeypatch):
    from app.api.v1.routes.auth import _login_ip_limiter, _login_phone_limiter

    monkeypatch.setattr(_login_ip_limiter, "_max_hits", 200)
    monkeypatch.setattr(_login_phone_limiter, "_max_hits", 200)


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


async def account(client):
    phone = _random_phone()
    data = (await _login(client, phone)).json()["data"]
    return phone, data["token"], UUID(data["user"]["id"])


async def enroll(client, token, password=PW):
    return await client.post(
        "/api/v1/auth/recovery-code", headers=bearer(token), json={"password": password}
    )


async def reset(client, phone, code, password="new-secret"):
    return await client.post(
        "/api/v1/auth/reset-password",
        json={
            "phone": phone,
            "recovery_code": code,
            "new_password": password,
        },
    )


async def access(client, token):
    return (await client.get("/api/v1/me/bootstrap", headers=bearer(token))).status_code


async def test_recovery_requires_password_and_real_bearer(client):
    _, token, uid = await account(client)
    assert (await enroll(client, token, "wrong-password")).status_code == 401
    assert await access(client, token) == 200
    assert (
        await client.post(
            "/api/v1/auth/recovery-code", headers={"X-User-Id": str(uid)}, json={"password": PW}
        )
    ).status_code == 401
    assert (
        await client.post("/api/v1/auth/recovery-code", json={"password": PW})
    ).status_code == 401


async def test_code_only_hash_stored_private_and_not_cached(client):
    _, token, uid = await account(client)
    res = await enroll(client, token)
    assert res.status_code == 200
    assert res.headers["cache-control"] == "no-store"
    code = res.json()["data"]["recovery_code"]
    assert len(code) >= 43
    async with async_session_maker() as session:
        user = await session.get(User, uid)
        assert user.recovery_code_hash == _hash_token(code)
        assert user.recovery_code_hash != code
    data = (await client.get("/api/v1/me/bootstrap", headers=bearer(token))).json()
    assert "recovery_code" not in str(data)


async def test_reset_revokes_all_old_sessions_and_consumes_code(client):
    phone, token, uid = await account(client)
    second = (await _login(client, phone)).json()["data"]["token"]
    _, other_token, _ = await account(client)
    code = (await enroll(client, token)).json()["data"]["recovery_code"]
    assert (await reset(client, phone, code)).status_code == 200
    assert await access(client, token) == 401
    assert await access(client, second) == 401
    assert await access(client, other_token) == 200
    assert (await reset(client, phone, code)).status_code == 401
    assert (await _login(client, phone, PW)).status_code == 401
    assert (await _login(client, phone, "new-secret")).status_code == 200
    async with async_session_maker() as session:
        assert (await session.get(User, uid)).recovery_code_hash is None


async def test_reset_error_does_not_enumerate_accounts(client):
    phone, _, _ = await account(client)
    missing = _random_phone()
    known = await reset(client, phone, "wrong-code")
    unknown = await reset(client, missing, "wrong-code")
    assert known.status_code == unknown.status_code == 401
    assert known.json()["error"] == unknown.json()["error"]


async def test_expired_and_rotated_code_rejected(client):
    phone, token, uid = await account(client)
    old = (await enroll(client, token)).json()["data"]["recovery_code"]
    new = (await enroll(client, token)).json()["data"]["recovery_code"]
    assert (await reset(client, phone, old)).status_code == 401
    async with async_session_maker() as session:
        user = await session.get(User, uid)
        user.recovery_expires_at = datetime.now(UTC) - timedelta(seconds=1)
        session.add(user)
        await session.commit()
    assert (await reset(client, phone, new)).status_code == 401
    assert await access(client, token) == 200


async def test_recovery_code_cannot_reset_another_account(client):
    phone, token, _ = await account(client)
    other_phone, other_token, _ = await account(client)
    code = (await enroll(client, token)).json()["data"]["recovery_code"]
    assert (await reset(client, other_phone, code)).status_code == 401
    assert await access(client, other_token) == 200
    assert (await reset(client, phone, code)).status_code == 200


async def test_logout_current_preserves_other_sessions(client):
    phone, token, _ = await account(client)
    second = (await _login(client, phone)).json()["data"]["token"]
    for _ in range(2):
        assert (await client.post("/api/v1/auth/logout", headers=bearer(token))).status_code == 200
    assert await access(client, token) == 401
    assert await access(client, second) == 200


async def test_logout_all_is_scoped_and_rejects_replay(client):
    phone, token, _ = await account(client)
    second = (await _login(client, phone)).json()["data"]["token"]
    _, other, other_uid = await account(client)
    res = await client.post(
        "/api/v1/auth/logout-all", headers=bearer(token), json={"user_id": str(other_uid)}
    )
    assert res.status_code == 200
    assert await access(client, token) == await access(client, second) == 401
    assert await access(client, other) == 200
    assert (await client.post("/api/v1/auth/logout-all", headers=bearer(token))).status_code == 401
    assert (
        await client.post("/api/v1/auth/logout-all", headers={"X-User-Id": str(other_uid)})
    ).status_code == 401


async def test_change_password_revokes_tokens_and_recovery_code(client):
    phone, token, _ = await account(client)
    second = (await _login(client, phone)).json()["data"]["token"]
    code = (await enroll(client, token)).json()["data"]["recovery_code"]
    res = await client.post(
        "/api/v1/auth/change-password",
        headers=bearer(token),
        json={"old_password": PW, "new_password": "changed-secret"},
    )
    assert res.status_code == 200
    assert await access(client, token) == await access(client, second) == 401
    assert (await reset(client, phone, code)).status_code == 401
    assert (await _login(client, phone, "changed-secret")).status_code == 200


async def test_legacy_session_cannot_supply_trusted_factor(client):
    phone = _random_phone()
    async with async_session_maker() as session:
        user = User(phone=phone, username=f"u{phone}", display_name="旧账号")
        session.add(user)
        await session.flush()
        uid = user.id
        token = await issue_session(session, uid, ttl_days=1)
    assert (await _login(client, phone)).status_code == 401
    assert (await enroll(client, token)).status_code == 401
    assert (
        await client.post(
            "/api/v1/auth/change-password",
            headers=bearer(token),
            json={"old_password": "", "new_password": PW},
        )
    ).status_code == 401
    assert (await reset(client, phone, "unverified-factor")).status_code == 401
    async with async_session_maker() as session:
        user = await session.get(User, uid)
        assert user.password_hash is None and user.recovery_code_hash is None


async def test_expired_session_cannot_enroll_or_revoke_all(client):
    _, token, _ = await account(client)
    async with async_session_maker() as session:
        row = (
            await session.execute(
                select(AuthSession).where(AuthSession.token_hash == _hash_token(token))
            )
        ).scalar_one()
        row.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        session.add(row)
        await session.commit()
    assert (await enroll(client, token)).status_code == 401
    assert (await client.post("/api/v1/auth/logout-all", headers=bearer(token))).status_code == 401


async def test_concurrent_reset_consumes_code_exactly_once(client):
    phone, token, _ = await account(client)
    code = (await enroll(client, token)).json()["data"]["recovery_code"]
    results = await asyncio.gather(
        reset(client, phone, code, "new-one"), reset(client, phone, code, "new-two")
    )
    assert sorted(r.status_code for r in results) == [200, 401]
    winning_password = "new-one" if results[0].status_code == 200 else "new-two"
    assert (await _login(client, phone, winning_password)).status_code == 200


async def test_concurrent_login_cannot_survive_password_reset(client):
    phone, token, _ = await account(client)
    code = (await enroll(client, token)).json()["data"]["recovery_code"]
    login, changed = await asyncio.gather(_login(client, phone), reset(client, phone, code))
    assert changed.status_code == 200
    assert login.status_code in (200, 401)
    if login.status_code == 200:
        assert await access(client, login.json()["data"]["token"]) == 401


async def test_waiting_sensitive_mutation_rechecks_revoked_token(client):
    from app.core.errors import AppError
    from app.services.auth import locked_user, revoke_all

    _, token, uid = await account(client)
    async with async_session_maker() as first, async_session_maker() as second:
        await locked_user(first, uid, token)
        waiting = asyncio.create_task(locked_user(second, uid, token))
        await asyncio.sleep(0.05)
        assert not waiting.done()
        await revoke_all(first, uid)
        await first.commit()
        with pytest.raises(AppError):
            await waiting


async def test_recovery_rate_limit_is_shared_and_normalized(client, monkeypatch):
    from app.api.v1.routes.auth import _login_phone_limiter

    phone, _, _ = await account(client)
    _login_phone_limiter.reset()
    monkeypatch.setattr(_login_phone_limiter, "_max_hits", 1)
    assert (await reset(client, phone, "wrong-code")).status_code == 401
    assert (await reset(client, "+86 " + phone, "wrong-code")).status_code == 429


async def test_auth_validation_does_not_echo_or_log_credentials(client, caplog):
    secret = "synthetic-sensitive-input-" * 10
    for path, body in [
        ("/auth/login", {"phone": _random_phone(), "password": secret}),
        (
            "/auth/reset-password",
            {"phone": _random_phone(), "recovery_code": secret, "new_password": secret},
        ),
        ("/auth/login", {"password": "synthetic-missing-phone-secret"}),
    ]:
        response = await client.post("/api/v1" + path, json=body)
        assert response.status_code == 422
        assert secret not in response.text and secret not in caplog.text
        assert "synthetic-missing-phone-secret" not in response.text
        assert "synthetic-missing-phone-secret" not in caplog.text


@pytest.mark.parametrize("password_hash", [None, ""])
async def test_passwordless_historical_token_cannot_access_data(client, password_hash):
    phone = _random_phone()
    async with async_session_maker() as session:
        user = User(
            phone=phone, username=f"u{phone}", display_name="历史用户", password_hash=password_hash
        )
        session.add(user)
        await session.flush()
        token = await issue_session(session, user.id, ttl_days=1)
    assert await access(client, token) == 401


async def test_concurrent_registration_cannot_overwrite_password(client):
    phone = _random_phone()
    first, second = await asyncio.gather(
        _login(client, phone, "password-one"), _login(client, phone, "password-two")
    )
    assert sorted(r.status_code for r in [first, second]) == [200, 401]
    winning_password = "password-one" if first.status_code == 200 else "password-two"
    assert (await _login(client, phone, winning_password)).status_code == 200


async def test_concurrent_rotation_and_reset_are_serialized(client):
    phone, token, _ = await account(client)
    code = (await enroll(client, token)).json()["data"]["recovery_code"]
    rotated, changed = await asyncio.gather(enroll(client, token), reset(client, phone, code))
    assert sorted(r.status_code for r in [rotated, changed]) == [200, 401]
    if rotated.status_code == 200:
        new_code = rotated.json()["data"]["recovery_code"]
        assert (await reset(client, phone, new_code)).status_code == 200
    assert await access(client, token) == 401


async def test_invalid_new_password_does_not_consume_recovery_code(client):
    phone, token, _ = await account(client)
    code = (await enroll(client, token)).json()["data"]["recovery_code"]
    assert (await reset(client, phone, code, "bad")).status_code == 422
    assert await access(client, token) == 200
    assert (await reset(client, phone, code)).status_code == 200


def test_dev_shim_is_disabled_by_default():
    from app.core.config import Settings

    assert Settings.model_fields["auth_dev_shim_enabled"].default is False


async def test_waiting_sensitive_mutation_rechecks_current_logout(client):
    from app.core.errors import AppError
    from app.services.auth import locked_user
    from app.services.session import revoke_session

    _, token, uid = await account(client)
    async with async_session_maker() as first, async_session_maker() as second:
        await locked_user(first, uid, token)
        waiting = asyncio.create_task(locked_user(second, uid, token))
        await asyncio.sleep(0.05)
        assert not waiting.done()
        await revoke_session(first, token)
        with pytest.raises(AppError):
            await waiting
