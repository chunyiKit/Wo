"""Notification list/mark + member_joined emission on invite accept."""

import uuid

from httpx import AsyncClient

XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}
XIAOBAO = {"X-User-Id": "019000a0-1100-7000-8000-000000000003"}


def _unique_name() -> str:
    return f"通知测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


async def _accept_invite_as(client: AsyncClient, fid: str, headers: dict) -> dict:
    """老陈 (owner) generates an invite, then `headers` user accepts it."""
    invite = (
        await client.post(
            f"/api/v1/families/{fid}/invitations",
            json={"role": "member"},
        )
    ).json()["data"]
    accept = await client.post(
        f"/api/v1/invitations/{invite['code']}/accept",
        headers=headers,
    )
    assert accept.status_code == 200, accept.text
    return accept.json()["data"]


async def test_accepting_invite_emits_member_joined_to_existing_members(
    client: AsyncClient,
) -> None:
    fid = await _create_family(client)

    # Scope counts to the family we just created — counting *all* member_joined
    # notifications is fragile because the listing is capped (LIMIT 50) and the
    # shared test DB accumulates rows across runs, so a global count saturates.
    def _joined_for_fid(notifs: list[dict]) -> list[dict]:
        return [
            n
            for n in notifs
            if n.get("type") == "member_joined" and n.get("family_id") == fid
        ]

    before = (await client.get("/api/v1/notifications")).json()["data"]
    before_count = len(_joined_for_fid(before))

    await _accept_invite_as(client, fid, XIAOLIN)

    after = (await client.get("/api/v1/notifications")).json()["data"]
    member_joined = _joined_for_fid(after)
    assert len(member_joined) == before_count + 1, "owner should receive a ping"
    newest = member_joined[0]
    assert "小林" in newest["title"]
    assert "加入" in newest["title"]
    assert newest["family_id"] == fid
    assert newest["read_at"] is None
    assert newest["deeplink"] and "/members" in newest["deeplink"]


async def test_joining_user_does_not_get_self_notification(
    client: AsyncClient,
) -> None:
    fid = await _create_family(client)
    await _accept_invite_as(client, fid, XIAOLIN)

    # 小林's own inbox should not contain a member_joined for this family.
    own = (await client.get("/api/v1/notifications", headers=XIAOLIN)).json()["data"]
    self_pings = [n for n in own if n.get("type") == "member_joined" and n.get("family_id") == fid]
    assert self_pings == [], "the actor shouldn't be notified of their own action"


async def test_mark_single_notification_read(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _accept_invite_as(client, fid, XIAOLIN)

    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    unread = next(n for n in notifs if n["family_id"] == fid and n["read_at"] is None)

    marked = await client.patch(f"/api/v1/notifications/{unread['id']}/read")
    assert marked.status_code == 200
    assert marked.json()["data"]["read_at"] is not None


async def test_mark_all_read_clears_unread_count(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _accept_invite_as(client, fid, XIAOLIN)
    # Trigger another one so there's at least 2 unread.
    fid2 = await _create_family(client)
    await _accept_invite_as(client, fid2, XIAOLIN)

    resp = await client.post("/api/v1/notifications/read-all")
    assert resp.status_code == 200
    assert resp.json()["data"]["marked"] >= 2

    boot = await client.get("/api/v1/me/bootstrap")
    assert boot.json()["data"]["unread_count"] == 0


async def test_cant_read_other_users_notification(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _accept_invite_as(client, fid, XIAOLIN)

    # Grab one of 老陈's notifications.
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    target = notifs[0]["id"]

    # 小宝 (not the recipient) tries to mark it read — should be hidden as 404.
    resp = await client.patch(
        f"/api/v1/notifications/{target}/read",
        headers=XIAOBAO,
    )
    assert resp.status_code == 404


async def test_list_respects_limit_query(client: AsyncClient) -> None:
    response = await client.get("/api/v1/notifications?limit=1")
    assert response.status_code == 200
    assert len(response.json()["data"]) <= 1


async def test_list_caps_at_100(client: AsyncClient) -> None:
    # limit=999 should clamp by FastAPI's Query validator (le=100).
    response = await client.get("/api/v1/notifications?limit=999")
    assert response.status_code == 422


async def test_delete_own_notification(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _accept_invite_as(client, fid, XIAOLIN)

    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    target = next(n for n in notifs if n["family_id"] == fid)

    resp = await client.delete(f"/api/v1/notifications/{target['id']}")
    assert resp.status_code == 200, resp.text

    after = (await client.get("/api/v1/notifications")).json()["data"]
    assert all(n["id"] != target["id"] for n in after), "deleted notification should be gone"


async def test_cant_delete_other_users_notification(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _accept_invite_as(client, fid, XIAOLIN)

    # 老陈's notification; 小宝 (not the owner) tries to delete → hidden as 404.
    target = (await client.get("/api/v1/notifications")).json()["data"][0]["id"]
    resp = await client.delete(f"/api/v1/notifications/{target}", headers=XIAOBAO)
    assert resp.status_code == 404
    # Still there for the real owner.
    after = (await client.get("/api/v1/notifications")).json()["data"]
    assert any(n["id"] == target for n in after)
