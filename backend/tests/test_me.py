import random

from httpx import AsyncClient

from app.core.ids import SEED_USER_ID


def _random_phone() -> str:
    return "1" + str(random.randint(3, 9)) + "".join(str(random.randint(0, 9)) for _ in range(9))


async def _register_user(client: AsyncClient) -> str:
    """Register a fresh user and return its id (doubles as the X-User-Id token)."""
    res = await client.post("/api/v1/auth/login", json={"phone": _random_phone()})
    return res.json()["data"]["user"]["id"]


async def test_me_returns_seed_user_with_extended_shape(client: AsyncClient) -> None:
    response = await client.get("/api/v1/me")
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    data = body["data"]

    user = data["user"]
    assert user["id"] == str(SEED_USER_ID)
    assert user["username"] == "laochen"
    assert user["display_name"] == "老陈"

    # current_family is either null or a FamilyRead — depends on prior test state.
    assert "current_family" in data

    stats = data["stats"]
    assert "families_joined" in stats
    assert stats["plugins_used"] == 0
    assert stats["days_active"] >= 0


async def test_patch_me_updates_display_name(client: AsyncClient) -> None:
    # 用新注册用户，避免污染共享测试库里的 seed 用户（其它用例断言其昵称）。
    user_id = await _register_user(client)
    headers = {"X-User-Id": user_id}

    response = await client.patch(
        "/api/v1/me", json={"display_name": "陈大山"}, headers=headers
    )
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    assert body["data"]["display_name"] == "陈大山"

    # 改动已落库：再读一次 /me 应返回新昵称。
    again = await client.get("/api/v1/me", headers=headers)
    assert again.json()["data"]["user"]["display_name"] == "陈大山"


async def test_patch_me_rejects_empty_display_name(client: AsyncClient) -> None:
    user_id = await _register_user(client)
    response = await client.patch(
        "/api/v1/me", json={"display_name": ""}, headers={"X-User-Id": user_id}
    )
    assert response.status_code == 422
