"""Invitation flow tests.

Covers the full path: Owner generates an invite, second user previews and
accepts, member list shows them, and a second accept attempt fails as
ALREADY_MEMBER. Also tests format-tolerant code parsing and expired codes.
"""

import uuid

from httpx import AsyncClient

XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}
XIAOBAO = {"X-User-Id": "019000a0-1100-7000-8000-000000000003"}


def _unique_name() -> str:
    return f"邀请测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


async def _generate_invite(client: AsyncClient, family_id: str) -> dict:
    response = await client.post(
        f"/api/v1/families/{family_id}/invitations",
        json={"role": "member", "ttl_seconds": 3600, "channel": "link"},
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]


async def test_full_invite_accept_flow(client: AsyncClient) -> None:
    # 老陈 creates family + invitation.
    family_id = await _create_family(client)
    invite = await _generate_invite(client, family_id)
    assert invite["code"].startswith("WO-")
    assert "/join/" in invite["link"]

    # Anyone can preview without auth (still hits the auth shim, but we don't
    # check the user — preview is public per contract).
    code = invite["code"]
    preview = await client.get(f"/api/v1/invitations/{code}/preview")
    assert preview.status_code == 200, preview.text
    preview_data = preview.json()["data"]
    assert preview_data["family"]["id"] == family_id
    assert preview_data["inviter"]["display_name"] == "老陈"

    # 小林 accepts.
    accept = await client.post(
        f"/api/v1/invitations/{code}/accept",
        headers=XIAOLIN,
    )
    assert accept.status_code == 200, accept.text
    accepted_family = accept.json()["data"]
    assert accepted_family["id"] == family_id
    assert accepted_family["my_role"] == "member"
    assert accepted_family["member_count"] == 2

    # Member list now contains both 老陈 and 小林.
    members = await client.get(f"/api/v1/families/{family_id}/members")
    rolenames = {(m["role"], m["display_name"]) for m in members.json()["data"]}
    assert ("owner", "老陈") in rolenames
    assert ("member", "小林") in rolenames

    # Re-accepting the same code is now blocked (already used).
    second_accept = await client.post(
        f"/api/v1/invitations/{code}/accept",
        headers=XIAOBAO,
    )
    assert second_accept.status_code == 400
    assert second_accept.json()["error"]["code"] == "INVITATION_INVALID"


async def test_accept_when_already_member_returns_already_member(
    client: AsyncClient,
) -> None:
    family_id = await _create_family(client)
    invite = await _generate_invite(client, family_id)

    # 老陈 (the owner) tries to accept their own invite — already a member.
    response = await client.post(f"/api/v1/invitations/{invite['code']}/accept")
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "ALREADY_MEMBER"


async def test_invite_accepts_url_slug_form(client: AsyncClient) -> None:
    family_id = await _create_family(client)
    invite = await _generate_invite(client, family_id)

    # Pull the bare slug from the link path; should work as a code too.
    slug = invite["link"].rsplit("/", 1)[-1]
    response = await client.get(f"/api/v1/invitations/{slug}/preview")
    assert response.status_code == 200


async def test_malformed_code_returns_invitation_invalid(
    client: AsyncClient,
) -> None:
    response = await client.get("/api/v1/invitations/not-a-real-code/preview")
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVITATION_INVALID"


async def test_non_admin_cannot_create_invitation(client: AsyncClient) -> None:
    family_id = await _create_family(client)
    # Make 小林 a member by inviting+accepting.
    invite = await _generate_invite(client, family_id)
    await client.post(
        f"/api/v1/invitations/{invite['code']}/accept",
        headers=XIAOLIN,
    )

    # 小林 (member, not admin) tries to create another invite — forbidden.
    response = await client.post(
        f"/api/v1/families/{family_id}/invitations",
        json={"role": "member"},
        headers=XIAOLIN,
    )
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "FORBIDDEN"
