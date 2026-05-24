"""Bootstrap aggregator (`GET /me/bootstrap`) — first-frame data in one shot."""

import uuid

from httpx import AsyncClient

XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}


def _unique_name() -> str:
    # Keep ≤ 16 chars (Family.name max_length).
    return f"bs-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


async def test_bootstrap_envelope_and_top_level_shape(client: AsyncClient) -> None:
    response = await client.get("/api/v1/me/bootstrap")
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    data = body["data"]

    for key in ("user", "current_family", "families", "installed_plugins", "unread_count"):
        assert key in data, f"missing top-level key: {key}"

    assert data["user"]["username"] == "laochen"
    assert isinstance(data["families"], list)
    assert isinstance(data["installed_plugins"], list)
    assert isinstance(data["unread_count"], int)


async def test_bootstrap_current_family_matches_user_setting(
    client: AsyncClient,
) -> None:
    fid = await _create_family(client)
    # `switch` makes this the current family (also runs implicitly on create).
    await client.post(f"/api/v1/families/{fid}/switch")

    data = (await client.get("/api/v1/me/bootstrap")).json()["data"]
    assert data["current_family"] is not None
    assert data["current_family"]["id"] == fid
    assert any(f["id"] == fid for f in data["families"])


async def test_bootstrap_includes_installed_plugins_with_preview(
    client: AsyncClient,
) -> None:
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/switch")
    await client.post(
        f"/api/v1/families/{fid}/plugins",
        json={"plugin_id": "anniversary"},
    )

    data = (await client.get("/api/v1/me/bootstrap")).json()["data"]
    plugins = data["installed_plugins"]
    assert any(p["plugin_id"] == "anniversary" for p in plugins)
    anniv = next(p for p in plugins if p["plugin_id"] == "anniversary")
    # Full shape: embedded plugin + layout + preview (same as /families/{id}/plugins).
    assert anniv["plugin"]["name"] == "纪念日"
    assert anniv["layout"]["cw"] == 2
    assert anniv["preview"]["color_token"] == "anniv"


async def test_bootstrap_unread_count_reflects_member_joined(
    client: AsyncClient,
) -> None:
    fid = await _create_family(client)

    before = (await client.get("/api/v1/me/bootstrap")).json()["data"]["unread_count"]

    # 小林 accepts an invitation → owner (老陈) gets a notification.
    invite = (
        await client.post(
            f"/api/v1/families/{fid}/invitations",
            json={"role": "member"},
        )
    ).json()["data"]
    await client.post(
        f"/api/v1/invitations/{invite['code']}/accept",
        headers=XIAOLIN,
    )

    after = (await client.get("/api/v1/me/bootstrap")).json()["data"]["unread_count"]
    assert after == before + 1
