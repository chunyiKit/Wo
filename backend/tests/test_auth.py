"""Phone-number login / register tests."""

import random

from httpx import AsyncClient


def _random_phone() -> str:
    # Valid CN mobile: leading 1, second digit 3-9, 11 digits total. Randomized
    # so repeated runs against the shared dev DB don't collide.
    return "1" + str(random.randint(3, 9)) + "".join(str(random.randint(0, 9)) for _ in range(9))


async def test_login_registers_new_phone(client: AsyncClient) -> None:
    phone = _random_phone()
    res = await client.post("/api/v1/auth/login", json={"phone": phone})
    assert res.status_code == 200
    body = res.json()
    assert body["success"] is True
    data = body["data"]
    assert data["is_new"] is True
    assert data["token"] == data["user"]["id"]
    assert data["user"]["display_name"].endswith(phone[-4:])


async def test_login_existing_phone_is_idempotent(client: AsyncClient) -> None:
    phone = _random_phone()
    first = (await client.post("/api/v1/auth/login", json={"phone": phone})).json()
    second = (await client.post("/api/v1/auth/login", json={"phone": phone})).json()

    assert first["data"]["is_new"] is True
    assert second["data"]["is_new"] is False
    # Same phone → same user identity.
    assert second["data"]["user"]["id"] == first["data"]["user"]["id"]


async def test_login_normalizes_formatting(client: AsyncClient) -> None:
    phone = _random_phone()
    plain = (await client.post("/api/v1/auth/login", json={"phone": phone})).json()
    # +86, spaces and dashes should resolve to the same user.
    fancy = (
        await client.post(
            "/api/v1/auth/login",
            json={"phone": f"+86 {phone[:3]}-{phone[3:7]}-{phone[7:]}"},
        )
    ).json()
    assert fancy["data"]["user"]["id"] == plain["data"]["user"]["id"]
    assert fancy["data"]["is_new"] is False


async def test_login_rejects_bad_phone(client: AsyncClient) -> None:
    res = await client.post("/api/v1/auth/login", json={"phone": "12345"})
    assert res.status_code == 422
    body = res.json()
    assert body["success"] is False
    assert body["error"]["code"] == "VALIDATION_ERROR"


async def test_login_seed_user(client: AsyncClient) -> None:
    # Seed user 老陈 is backfilled with this phone by the p5 migration.
    res = await client.post("/api/v1/auth/login", json={"phone": "13800000001"})
    data = res.json()["data"]
    assert data["is_new"] is False
    assert data["user"]["display_name"] == "老陈"
