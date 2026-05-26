"""Member management tests — leaving a family.

Reuses the invite→accept path to make a non-owner member, then exercises the
DELETE /families/{id}/members/me endpoint and its guard rails.
"""

import uuid

from httpx import AsyncClient

XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}


def _unique_name() -> str:
    return f"离开测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


async def _invite_code(client: AsyncClient, family_id: str) -> str:
    response = await client.post(
        f"/api/v1/families/{family_id}/invitations",
        json={"role": "member", "ttl_seconds": 3600, "channel": "link"},
    )
    return response.json()["data"]["code"]


async def test_member_can_leave_family(client: AsyncClient) -> None:
    # 老陈 creates, 小林 joins.
    family_id = await _create_family(client)
    code = await _invite_code(client, family_id)
    await client.post(f"/api/v1/invitations/{code}/accept", headers=XIAOLIN)

    # 小林 leaves.
    response = await client.delete(
        f"/api/v1/families/{family_id}/members/me",
        headers=XIAOLIN,
    )
    assert response.status_code == 200, response.text

    # Member list is back to just the owner.
    members = await client.get(f"/api/v1/families/{family_id}/members")
    user_ids = {m["user_id"] for m in members.json()["data"]}
    assert XIAOLIN["X-User-Id"] not in user_ids

    # 小林 is no longer standing in this family (switched away or cleared).
    me = (await client.get("/api/v1/me", headers=XIAOLIN)).json()["data"]
    current = me["current_family"]
    assert current is None or current["id"] != family_id

    # 小林 can no longer read the family (no longer a member).
    reread = await client.get(f"/api/v1/families/{family_id}", headers=XIAOLIN)
    assert reread.status_code == 404


async def test_owner_cannot_leave(client: AsyncClient) -> None:
    family_id = await _create_family(client)
    response = await client.delete(f"/api/v1/families/{family_id}/members/me")
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "FORBIDDEN"


async def test_non_member_leave_is_404(client: AsyncClient) -> None:
    family_id = await _create_family(client)
    # 小林 is not a member.
    response = await client.delete(
        f"/api/v1/families/{family_id}/members/me",
        headers=XIAOLIN,
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "FAMILY_NOT_FOUND"


async def _family_with_member(client: AsyncClient) -> str:
    """老陈 owns a fresh family; 小林 joins as a member. Returns family_id."""
    family_id = await _create_family(client)
    code = await _invite_code(client, family_id)
    await client.post(f"/api/v1/invitations/{code}/accept", headers=XIAOLIN)
    return family_id


def _role_of(members: list[dict], user_id: str) -> str:
    return next(m["role"] for m in members if m["user_id"] == user_id)


async def test_owner_can_change_member_role(client: AsyncClient) -> None:
    family_id = await _family_with_member(client)

    response = await client.patch(
        f"/api/v1/families/{family_id}/members/{XIAOLIN['X-User-Id']}",
        json={"role": "admin"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["data"]["role"] == "admin"

    members = (await client.get(f"/api/v1/families/{family_id}/members")).json()["data"]
    assert _role_of(members, XIAOLIN["X-User-Id"]) == "admin"


async def test_member_cannot_change_roles(client: AsyncClient) -> None:
    family_id = await _family_with_member(client)
    # 小林 (a plain member) tries to promote themselves — forbidden.
    response = await client.patch(
        f"/api/v1/families/{family_id}/members/{XIAOLIN['X-User-Id']}",
        json={"role": "admin"},
        headers=XIAOLIN,
    )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "FORBIDDEN"


async def test_cannot_set_role_to_owner(client: AsyncClient) -> None:
    family_id = await _family_with_member(client)
    response = await client.patch(
        f"/api/v1/families/{family_id}/members/{XIAOLIN['X-User-Id']}",
        json={"role": "owner"},
    )
    assert response.status_code == 422


async def test_cannot_change_owner_role(client: AsyncClient) -> None:
    family_id = await _family_with_member(client)
    # Promote 小林 to admin, then 小林 tries to demote the owner 老陈.
    await client.patch(
        f"/api/v1/families/{family_id}/members/{XIAOLIN['X-User-Id']}",
        json={"role": "admin"},
    )
    owner_id = "019000a0-1100-7000-8000-000000000001"  # 老陈 (seed user)
    response = await client.patch(
        f"/api/v1/families/{family_id}/members/{owner_id}",
        json={"role": "member"},
        headers=XIAOLIN,
    )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "FORBIDDEN"


async def test_transfer_ownership(client: AsyncClient) -> None:
    family_id = await _family_with_member(client)
    owner_id = "019000a0-1100-7000-8000-000000000001"

    response = await client.post(
        f"/api/v1/families/{family_id}/transfer-ownership",
        json={"new_owner_id": XIAOLIN["X-User-Id"]},
    )
    assert response.status_code == 200, response.text

    members = (await client.get(f"/api/v1/families/{family_id}/members")).json()["data"]
    assert _role_of(members, XIAOLIN["X-User-Id"]) == "owner"
    assert _role_of(members, owner_id) == "admin"


async def test_non_owner_cannot_transfer(client: AsyncClient) -> None:
    family_id = await _family_with_member(client)
    # 小林 (member) tries to seize ownership — forbidden.
    response = await client.post(
        f"/api/v1/families/{family_id}/transfer-ownership",
        json={"new_owner_id": XIAOLIN["X-User-Id"]},
        headers=XIAOLIN,
    )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "FORBIDDEN"


async def test_transfer_to_self_is_422(client: AsyncClient) -> None:
    family_id = await _family_with_member(client)
    owner_id = "019000a0-1100-7000-8000-000000000001"
    response = await client.post(
        f"/api/v1/families/{family_id}/transfer-ownership",
        json={"new_owner_id": owner_id},
    )
    assert response.status_code == 422
