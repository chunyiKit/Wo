"""Plugin platform tests — marketplace, install/uninstall, layout validation."""

import uuid

from httpx import AsyncClient

XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}


def _unique_name() -> str:
    return f"插件测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


# ---- Marketplace -----------------------------------------------------------


async def test_marketplace_lists_anniversary(client: AsyncClient) -> None:
    response = await client.get("/api/v1/plugins")
    assert response.status_code == 200
    ids = [p["id"] for p in response.json()["data"]]
    assert "anniversary" in ids


async def test_marketplace_hides_unpublished_plugins(client: AsyncClient) -> None:
    """`photo` is marked published=False (backend exists, App UI not wired)
    so the marketplace must not surface it for new installs. The detail
    endpoint stays accessible by id — for any family that already has it
    installed, bootstrap still needs the manifest."""
    response = await client.get("/api/v1/plugins")
    ids = {p["id"] for p in response.json()["data"]}
    assert "photo" not in ids
    # Single-plugin detail endpoint is not gated — installed families need it.
    detail = await client.get("/api/v1/plugins/photo")
    assert detail.status_code == 200


async def test_marketplace_plugin_detail(client: AsyncClient) -> None:
    response = await client.get("/api/v1/plugins/anniversary")
    assert response.status_code == 200
    plugin = response.json()["data"]
    assert plugin["name"] == "纪念日"
    assert plugin["category"] == "life"
    assert plugin["color_token"] == "anniv"


async def test_marketplace_unknown_plugin_404(client: AsyncClient) -> None:
    response = await client.get("/api/v1/plugins/__does_not_exist__")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"


# ---- Install ---------------------------------------------------------------


async def test_install_uses_manifest_default_layout(client: AsyncClient) -> None:
    fid = await _create_family(client)
    response = await client.post(
        f"/api/v1/families/{fid}/plugins",
        json={"plugin_id": "anniversary"},
    )
    assert response.status_code == 201, response.text
    ip = response.json()["data"]
    assert ip["plugin_id"] == "anniversary"
    # First install in a fresh family lands at (0, 0) with manifest default 2x2.
    assert ip["layout"] == {"col": 0, "row": 0, "cw": 2, "ch": 2}


async def test_install_single_instance_twice_returns_409(client: AsyncClient) -> None:
    # photo is single-instance → installing it twice is rejected.
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "photo"})
    response = await client.post(
        f"/api/v1/families/{fid}/plugins",
        json={"plugin_id": "photo"},
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "PLUGIN_ALREADY_INSTALLED"


async def test_install_multi_instance_allows_many(client: AsyncClient) -> None:
    # anniversary is multi_instance → a family can install several cards.
    fid = await _create_family(client)
    first = await client.post(
        f"/api/v1/families/{fid}/plugins", json={"plugin_id": "anniversary"}
    )
    second = await client.post(
        f"/api/v1/families/{fid}/plugins", json={"plugin_id": "anniversary"}
    )
    assert first.status_code == 201, first.text
    assert second.status_code == 201, second.text
    assert first.json()["data"]["id"] != second.json()["data"]["id"]

    listing = await client.get(f"/api/v1/families/{fid}/plugins")
    anniv_cards = [p for p in listing.json()["data"] if p["plugin_id"] == "anniversary"]
    assert len(anniv_cards) == 2


async def test_install_unknown_plugin_404(client: AsyncClient) -> None:
    fid = await _create_family(client)
    response = await client.post(
        f"/api/v1/families/{fid}/plugins",
        json={"plugin_id": "__does_not_exist__"},
    )
    assert response.status_code == 404


async def test_install_requires_admin(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # Invite 小林 as member.
    invite = (
        await client.post(
            f"/api/v1/families/{fid}/invitations",
            json={"role": "member"},
        )
    ).json()["data"]
    await client.post(f"/api/v1/invitations/{invite['code']}/accept", headers=XIAOLIN)

    # 小林 (member, not admin) tries to install — forbidden.
    response = await client.post(
        f"/api/v1/families/{fid}/plugins",
        json={"plugin_id": "anniversary"},
        headers=XIAOLIN,
    )
    assert response.status_code == 403


async def test_install_explicit_layout_overflow_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # col=3 + cw=2 = 5 > grid width 4.
    response = await client.post(
        f"/api/v1/families/{fid}/plugins",
        json={
            "plugin_id": "anniversary",
            "layout": {"col": 3, "row": 0, "cw": 2, "ch": 2},
        },
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "LAYOUT_CONFLICT"


# ---- List installed --------------------------------------------------------


async def test_list_installed_includes_preview_and_plugin(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "anniversary"})

    response = await client.get(f"/api/v1/families/{fid}/plugins")
    assert response.status_code == 200
    items = response.json()["data"]
    assert len(items) == 1
    item = items[0]
    # Embedded plugin object.
    assert item["plugin"]["name"] == "纪念日"
    # Preview comes from the plugin's preview hook.
    assert item["preview"]["color_token"] == "anniv"
    assert "primary" in item["preview"]


# ---- Uninstall -------------------------------------------------------------


async def test_uninstall_removes_install(client: AsyncClient) -> None:
    fid = await _create_family(client)
    ip = (
        await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "anniversary"})
    ).json()["data"]

    response = await client.delete(f"/api/v1/families/{fid}/plugins/{ip['id']}")
    assert response.status_code == 200

    listing = await client.get(f"/api/v1/families/{fid}/plugins")
    assert listing.json()["data"] == []


async def test_uninstall_unknown_id_returns_404(client: AsyncClient) -> None:
    fid = await _create_family(client)
    fake_id = str(uuid.uuid4())
    response = await client.delete(f"/api/v1/families/{fid}/plugins/{fake_id}")
    assert response.status_code == 404


# ---- Layout update ---------------------------------------------------------


async def test_layout_update_moves_plugin(client: AsyncClient) -> None:
    fid = await _create_family(client)
    ip = (
        await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "anniversary"})
    ).json()["data"]

    response = await client.put(
        f"/api/v1/families/{fid}/layout",
        json={
            "items": [
                {"install_id": ip["id"], "col": 2, "row": 0, "cw": 2, "ch": 2},
            ],
        },
    )
    assert response.status_code == 200, response.text
    moved = response.json()["data"][0]
    assert moved["layout"] == {"col": 2, "row": 0, "cw": 2, "ch": 2}


async def test_layout_update_missing_item_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "anniversary"})

    # Empty items but family has 1 installed plugin → mismatch.
    response = await client.put(f"/api/v1/families/{fid}/layout", json={"items": []})
    assert response.status_code == 409
    body = response.json()
    assert body["error"]["code"] == "LAYOUT_CONFLICT"
    assert body["error"]["details"]["missing"]


async def test_layout_update_overflow_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    ip = (
        await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "anniversary"})
    ).json()["data"]

    response = await client.put(
        f"/api/v1/families/{fid}/layout",
        json={
            "items": [
                {"install_id": ip["id"], "col": 3, "row": 0, "cw": 2, "ch": 2},
            ],
        },
    )
    assert response.status_code == 409


# ---- Per-card config (anniversary binding) ---------------------------------


async def _create_anniversary(client: AsyncClient, fid: str, name: str) -> str:
    created = await client.post(
        f"/api/v1/families/{fid}/plugins/anniversary/dates",
        json={"name": name, "event_date": "2024-03-15"},
    )
    return created.json()["data"]["id"]


async def test_install_with_config_pins_anniversary(client: AsyncClient) -> None:
    fid = await _create_family(client)
    a_id = await _create_anniversary(client, fid, "结婚纪念日")
    await _create_anniversary(client, fid, "宝宝生日")

    response = await client.post(
        f"/api/v1/families/{fid}/plugins",
        json={"plugin_id": "anniversary", "config": {"anniversary_id": a_id}},
    )
    assert response.status_code == 201, response.text
    data = response.json()["data"]
    assert data["config"] == {"anniversary_id": a_id}
    assert data["preview"]["primary"] == "结婚纪念日"
    # Card shows the anniversary's own emoji, not the plugin's 🎂.
    assert data["preview"]["emoji"] == "💞"


async def test_two_cards_show_their_own_pinned_dates(client: AsyncClient) -> None:
    fid = await _create_family(client)
    a_id = await _create_anniversary(client, fid, "结婚纪念日")
    b_id = await _create_anniversary(client, fid, "宝宝生日")

    await client.post(
        f"/api/v1/families/{fid}/plugins",
        json={"plugin_id": "anniversary", "config": {"anniversary_id": a_id}},
    )
    await client.post(
        f"/api/v1/families/{fid}/plugins",
        json={"plugin_id": "anniversary", "config": {"anniversary_id": b_id}},
    )

    listing = await client.get(f"/api/v1/families/{fid}/plugins")
    primaries = {p["preview"]["primary"] for p in listing.json()["data"]}
    assert any("结婚纪念日" in p for p in primaries)
    assert any("宝宝生日" in p for p in primaries)


async def test_patch_config_rebinds_card(client: AsyncClient) -> None:
    fid = await _create_family(client)
    a_id = await _create_anniversary(client, fid, "结婚纪念日")
    b_id = await _create_anniversary(client, fid, "宝宝生日")
    ip = (
        await client.post(
            f"/api/v1/families/{fid}/plugins",
            json={"plugin_id": "anniversary", "config": {"anniversary_id": a_id}},
        )
    ).json()["data"]

    patched = await client.patch(
        f"/api/v1/families/{fid}/plugins/{ip['id']}",
        json={"config": {"anniversary_id": b_id}},
    )
    assert patched.status_code == 200, patched.text
    data = patched.json()["data"]
    assert data["config"] == {"anniversary_id": b_id}
    assert "宝宝生日" in data["preview"]["primary"]


async def test_pinned_deleted_falls_back_to_overview(client: AsyncClient) -> None:
    fid = await _create_family(client)
    a_id = await _create_anniversary(client, fid, "结婚纪念日")
    ip = (
        await client.post(
            f"/api/v1/families/{fid}/plugins",
            json={"plugin_id": "anniversary", "config": {"anniversary_id": a_id}},
        )
    ).json()["data"]

    await client.delete(f"/api/v1/families/{fid}/plugins/anniversary/dates/{a_id}")

    listing = await client.get(f"/api/v1/families/{fid}/plugins")
    card = next(p for p in listing.json()["data"] if p["id"] == ip["id"])
    assert card["preview"]["primary"] == "还没有记录"


async def test_patch_config_unknown_install_404(client: AsyncClient) -> None:
    fid = await _create_family(client)
    fake = str(uuid.uuid4())
    response = await client.patch(
        f"/api/v1/families/{fid}/plugins/{fake}",
        json={"config": {"anniversary_id": fake}},
    )
    assert response.status_code == 404
