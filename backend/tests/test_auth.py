"""Phone-number login / register + password tests."""

import random

from httpx import AsyncClient

PW = "secret123"


def _random_phone() -> str:
    # Valid CN mobile: leading 1, second digit 3-9, 11 digits total. Randomized
    # so repeated runs against the shared dev DB don't collide.
    return "1" + str(random.randint(3, 9)) + "".join(str(random.randint(0, 9)) for _ in range(9))


async def _login(client: AsyncClient, phone: str, password: str = PW):
    return await client.post(
        "/api/v1/auth/login", json={"phone": phone, "password": password}
    )


async def test_login_registers_new_phone(client: AsyncClient) -> None:
    phone = _random_phone()
    res = await _login(client, phone)
    assert res.status_code == 200
    body = res.json()
    assert body["success"] is True
    data = body["data"]
    assert data["is_new"] is True
    # The token is now an opaque session token, not the user id.
    assert data["token"]
    assert data["token"] != data["user"]["id"]
    assert data["user"]["display_name"].endswith(phone[-4:])


async def test_login_existing_phone_is_idempotent(client: AsyncClient) -> None:
    phone = _random_phone()
    first = (await _login(client, phone)).json()
    second = (await _login(client, phone)).json()

    assert first["data"]["is_new"] is True
    assert second["data"]["is_new"] is False
    assert second["data"]["user"]["id"] == first["data"]["user"]["id"]


async def test_login_normalizes_formatting(client: AsyncClient) -> None:
    phone = _random_phone()
    plain = (await _login(client, phone)).json()
    fancy = (
        await client.post(
            "/api/v1/auth/login",
            json={
                "phone": f"+86 {phone[:3]}-{phone[3:7]}-{phone[7:]}",
                "password": PW,
            },
        )
    ).json()
    assert fancy["data"]["user"]["id"] == plain["data"]["user"]["id"]
    assert fancy["data"]["is_new"] is False


async def test_login_rejects_bad_phone(client: AsyncClient) -> None:
    res = await _login(client, "12345")
    assert res.status_code == 422
    body = res.json()
    assert body["success"] is False
    assert body["error"]["code"] == "VALIDATION_ERROR"


# ---- password ---------------------------------------------------------------


async def test_wrong_password_rejected(client: AsyncClient) -> None:
    phone = _random_phone()
    await _login(client, phone, PW)  # register
    bad = await _login(client, phone, "wrongpass")
    assert bad.status_code == 401
    assert bad.json()["error"]["code"] == "UNAUTHORIZED"
    # Correct password still works.
    good = await _login(client, phone, PW)
    assert good.status_code == 200


async def test_short_password_rejected(client: AsyncClient) -> None:
    res = await _login(client, _random_phone(), "123")
    assert res.status_code == 422
    assert res.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_legacy_user_first_login_sets_password(client: AsyncClient) -> None:
    """A pre-existing account with no password gets one set on first login,
    then must use it thereafter."""
    from app.core.database import async_session_maker
    from app.models.user import User

    phone = _random_phone()
    async with async_session_maker() as session:
        session.add(
            User(
                phone=phone,
                username=f"u{phone}",
                display_name="老用户",
                password_hash=None,
            )
        )
        await session.commit()

    # First login sets the password (existing account → is_new False).
    first = await _login(client, phone, "firstpass")
    assert first.status_code == 200
    assert first.json()["data"]["is_new"] is False

    # Now it's verified: the set password works, a different one is rejected.
    assert (await _login(client, phone, "firstpass")).status_code == 200
    assert (await _login(client, phone, "nope999")).status_code == 401


async def test_change_password(client: AsyncClient) -> None:
    phone = _random_phone()
    reg = (await _login(client, phone, "oldpass1")).json()["data"]
    uid = reg["user"]["id"]

    changed = await client.post(
        "/api/v1/auth/change-password",
        headers={"X-User-Id": uid},
        json={"old_password": "oldpass1", "new_password": "newpass2"},
    )
    assert changed.status_code == 200
    assert changed.json()["data"]["changed"] is True

    # Old password no longer works; new one does.
    assert (await _login(client, phone, "oldpass1")).status_code == 401
    assert (await _login(client, phone, "newpass2")).status_code == 200


async def test_change_password_wrong_old_rejected(client: AsyncClient) -> None:
    phone = _random_phone()
    uid = (await _login(client, phone, "oldpass1")).json()["data"]["user"]["id"]
    res = await client.post(
        "/api/v1/auth/change-password",
        headers={"X-User-Id": uid},
        json={"old_password": "WRONG", "new_password": "newpass2"},
    )
    assert res.status_code == 401


async def test_change_password_short_rejected(client: AsyncClient) -> None:
    phone = _random_phone()
    uid = (await _login(client, phone, "oldpass1")).json()["data"]["user"]["id"]
    res = await client.post(
        "/api/v1/auth/change-password",
        headers={"X-User-Id": uid},
        json={"old_password": "oldpass1", "new_password": "12"},
    )
    assert res.status_code == 422


# ---- rate limiting ----------------------------------------------------------


async def test_login_rate_limited_after_burst(client: AsyncClient) -> None:
    from app.core.config import settings

    for _ in range(settings.login_rate_limit_max):
        ok_res = await _login(client, _random_phone())
        assert ok_res.status_code == 200

    blocked = await _login(client, _random_phone())
    assert blocked.status_code == 429
    body = blocked.json()
    assert body["success"] is False
    assert body["error"]["code"] == "RATE_LIMIT"


async def test_login_rate_limited_per_phone(client: AsyncClient) -> None:
    from app.core.config import settings

    phone = _random_phone()
    assert settings.login_rate_limit_per_phone_max < settings.login_rate_limit_max
    for _ in range(settings.login_rate_limit_per_phone_max):
        ok_res = await _login(client, phone)
        assert ok_res.status_code == 200

    blocked = await _login(client, phone)
    assert blocked.status_code == 429
    assert blocked.json()["error"]["code"] == "RATE_LIMIT"

    other = await _login(client, _random_phone())
    assert other.status_code == 200


# ---- session bearer tokens --------------------------------------------------


async def test_bearer_token_authenticates(client: AsyncClient) -> None:
    token = (await _login(client, _random_phone())).json()["data"]["token"]
    # No X-User-Id — auth comes purely from the bearer token.
    res = await client.get(
        "/api/v1/me/bootstrap", headers={"Authorization": f"Bearer {token}"}
    )
    assert res.status_code == 200
    assert res.json()["data"]["user"]["id"]


async def test_invalid_bearer_rejected(client: AsyncClient) -> None:
    res = await client.get(
        "/api/v1/me/bootstrap",
        headers={"Authorization": "Bearer not-a-real-token"},
    )
    assert res.status_code == 401


async def test_logout_revokes_token(client: AsyncClient) -> None:
    token = (await _login(client, _random_phone())).json()["data"]["token"]
    auth = {"Authorization": f"Bearer {token}"}
    assert (await client.get("/api/v1/me/bootstrap", headers=auth)).status_code == 200

    out = await client.post("/api/v1/auth/logout", headers=auth)
    assert out.status_code == 200
    # Token is dead immediately after logout.
    assert (await client.get("/api/v1/me/bootstrap", headers=auth)).status_code == 401


async def test_shim_disabled_blocks_xuserid_but_bearer_works(
    client: AsyncClient, monkeypatch
) -> None:
    """With the dev shim off (production), X-User-Id is ignored and only a real
    bearer token authenticates."""
    from app.core import auth as auth_module

    token = (await _login(client, _random_phone())).json()["data"]["token"]
    uid = (await _login(client, _random_phone())).json()["data"]["user"]["id"]

    monkeypatch.setattr(auth_module.settings, "auth_dev_shim_enabled", False)

    # X-User-Id no longer works.
    blocked = await client.get("/api/v1/me/bootstrap", headers={"X-User-Id": uid})
    assert blocked.status_code == 401
    # No header at all → no seed-user fallback either.
    nobody = await client.get("/api/v1/me/bootstrap")
    assert nobody.status_code == 401
    # A real bearer token still authenticates.
    ok_res = await client.get(
        "/api/v1/me/bootstrap", headers={"Authorization": f"Bearer {token}"}
    )
    assert ok_res.status_code == 200


async def test_login_seed_user(client: AsyncClient) -> None:
    # Seed user 老陈 (phone backfilled by p5). First login with a password sets
    # it; the same password is idempotent across runs against the shared DB.
    res = await _login(client, "13800000001", "laochen-pw")
    assert res.status_code == 200
    data = res.json()["data"]
    assert data["is_new"] is False
    assert data["user"]["display_name"] == "老陈"
