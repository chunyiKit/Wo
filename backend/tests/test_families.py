"""Golden-path tests for family creation + listing + switching.

Each test uses unique family names so it doesn't collide with sibling tests
or prior runs (the DB persists across the test session).
"""

import uuid

from httpx import AsyncClient


def _unique_name() -> str:
    """8-char unique suffix so test runs don't collide on data."""
    return f"测试家-{uuid.uuid4().hex[:8]}"


async def test_create_family_makes_creator_owner(client: AsyncClient) -> None:
    name = _unique_name()
    response = await client.post(
        "/api/v1/families",
        json={"name": name, "slogan": "测试用", "emoji": "🏡"},
    )
    assert response.status_code == 201
    family = response.json()["data"]
    assert family["name"] == name
    assert family["emoji"] == "🏡"
    assert family["my_role"] == "owner"
    assert family["member_count"] == 1


async def test_get_family_returns_member_view(client: AsyncClient) -> None:
    # Create one first.
    create = await client.post("/api/v1/families", json={"name": _unique_name()})
    family_id = create.json()["data"]["id"]

    response = await client.get(f"/api/v1/families/{family_id}")
    assert response.status_code == 200
    assert response.json()["data"]["id"] == family_id
    assert response.json()["data"]["my_role"] == "owner"


async def test_get_family_404_when_non_member(client: AsyncClient) -> None:
    # 老陈 creates a family.
    create = await client.post("/api/v1/families", json={"name": _unique_name()})
    family_id = create.json()["data"]["id"]

    # 小林 (not a member) tries to read — should get FAMILY_NOT_FOUND, not 200.
    response = await client.get(
        f"/api/v1/families/{family_id}",
        headers={"X-User-Id": "019000a0-1100-7000-8000-000000000002"},
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "FAMILY_NOT_FOUND"


async def test_me_families_lists_created_family(client: AsyncClient) -> None:
    name = _unique_name()
    await client.post("/api/v1/families", json={"name": name})

    response = await client.get("/api/v1/me/families")
    assert response.status_code == 200
    names = [f["name"] for f in response.json()["data"]]
    assert name in names


async def test_switch_family_updates_current(client: AsyncClient) -> None:
    create = await client.post("/api/v1/families", json={"name": _unique_name()})
    family_id = create.json()["data"]["id"]

    switch = await client.post(f"/api/v1/families/{family_id}/switch")
    assert switch.status_code == 200

    me = (await client.get("/api/v1/me")).json()["data"]
    assert me["current_family"]["id"] == family_id


async def test_switch_to_non_member_family_is_404(client: AsyncClient) -> None:
    # 老陈 creates.
    create = await client.post("/api/v1/families", json={"name": _unique_name()})
    family_id = create.json()["data"]["id"]

    # 小林 tries to switch — not a member.
    response = await client.post(
        f"/api/v1/families/{family_id}/switch",
        headers={"X-User-Id": "019000a0-1100-7000-8000-000000000002"},
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "FAMILY_NOT_FOUND"
