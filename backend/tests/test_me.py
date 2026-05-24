from httpx import AsyncClient

from app.core.ids import SEED_USER_ID


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
