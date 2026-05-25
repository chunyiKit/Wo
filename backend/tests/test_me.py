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


async def test_patch_me_syncs_membership_and_accounting_name(client: AsyncClient) -> None:
    """改昵称应同步到家庭成员身份，记账记录里的 creator_name 随之更新。"""
    user_id = await _register_user(client)
    headers = {"X-User-Id": user_id}

    # 建家庭：creator 的 membership.display_name 是注册时的默认昵称快照。
    fid = (
        await client.post("/api/v1/families", json={"name": "同步测试之家"}, headers=headers)
    ).json()["data"]["id"]
    created = (
        await client.post(
            f"/api/v1/families/{fid}/plugins/accounting/transactions",
            json={"amount": "12.00", "category": "dining"},
            headers=headers,
        )
    ).json()["data"]
    old_name = created["creator_name"]
    assert old_name is not None

    # 改昵称。
    await client.patch("/api/v1/me", json={"display_name": "新昵称"}, headers=headers)

    # 既有记账记录的 creator_name 应反映新昵称（成员身份已同步）。
    rows = (
        await client.get(
            f"/api/v1/families/{fid}/plugins/accounting/transactions", headers=headers
        )
    ).json()["data"]
    assert rows[0]["creator_name"] == "新昵称"
    assert old_name != "新昵称"
