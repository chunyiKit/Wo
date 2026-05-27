"""Stock (囤货铺) plugin tests — stock CRUD, shopping-list CRUD, the two
linkage actions (low → to-buy, bought → into stock), and the home preview."""

import uuid

from httpx import AsyncClient

# Seed users (see app/core/seed.py): 老陈 owns by default, 小宝 is an outsider.
LAOCHEN = "019000a0-1100-7000-8000-000000000001"
XIAOBAO = {"X-User-Id": "019000a0-1100-7000-8000-000000000003"}

ITEMS = "/api/v1/families/{fid}/plugins/stock/items"
BUYS = "/api/v1/families/{fid}/plugins/stock/buys"


def _unique_name() -> str:
    return f"囤货测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


async def test_create_and_list_item(client: AsyncClient) -> None:
    fid = await _create_family(client)
    create = await client.post(
        ITEMS.format(fid=fid),
        json={"name": "卫生纸", "emoji": "🧻", "qty": 6, "unit": "卷", "low_at": 2},
    )
    assert create.status_code == 201, create.text
    data = create.json()["data"]
    assert data["name"] == "卫生纸"
    assert data["qty"] == 6
    assert data["is_low"] is False

    listed = await client.get(ITEMS.format(fid=fid))
    assert listed.status_code == 200
    assert len(listed.json()["data"]) == 1


async def test_is_low_flag(client: AsyncClient) -> None:
    fid = await _create_family(client)
    create = await client.post(
        ITEMS.format(fid=fid), json={"name": "洗衣液", "qty": 1, "low_at": 1}
    )
    assert create.json()["data"]["is_low"] is True


async def test_list_low_filter(client: AsyncClient) -> None:
    fid = await _create_family(client)
    base = ITEMS.format(fid=fid)
    low_id = (await client.post(base, json={"name": "盐", "qty": 0, "low_at": 1})).json()["data"][
        "id"
    ]
    await client.post(base, json={"name": "米", "qty": 10, "low_at": 2})

    low_only = await client.get(base, params={"low": "true"})
    ids = {i["id"] for i in low_only.json()["data"]}
    assert ids == {low_id}


async def test_blank_name_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    create = await client.post(ITEMS.format(fid=fid), json={"name": "   "})
    assert create.status_code == 400
    assert create.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_update_and_delete_item(client: AsyncClient) -> None:
    fid = await _create_family(client)
    base = ITEMS.format(fid=fid)
    iid = (await client.post(base, json={"name": "牙膏", "qty": 3})).json()["data"]["id"]

    updated = await client.put(f"{base}/{iid}", json={"qty": 1, "low_at": 1})
    assert updated.status_code == 200
    assert updated.json()["data"]["is_low"] is True

    deleted = await client.delete(f"{base}/{iid}")
    assert deleted.status_code == 200
    remaining = (await client.get(base)).json()["data"]
    assert all(i["id"] != iid for i in remaining)


async def test_create_and_list_buy(client: AsyncClient) -> None:
    fid = await _create_family(client)
    create = await client.post(
        BUYS.format(fid=fid), json={"name": "鸡蛋", "want_qty": "一打"}
    )
    assert create.status_code == 201, create.text
    data = create.json()["data"]
    assert data["name"] == "鸡蛋"
    assert data["bought"] is False
    assert data["stock_item_id"] is None


async def test_to_buy_links_and_dedups(client: AsyncClient) -> None:
    fid = await _create_family(client)
    iid = (
        await client.post(
            ITEMS.format(fid=fid), json={"name": "酱油", "unit": "瓶", "qty": 0, "low_at": 1}
        )
    ).json()["data"]["id"]

    first = await client.post(f"{ITEMS.format(fid=fid)}/{iid}/to-buy")
    assert first.status_code == 201, first.text
    buy = first.json()["data"]
    assert buy["name"] == "酱油"
    assert buy["stock_item_id"] == iid
    assert buy["want_qty"] == "瓶"

    # A second to-buy while the first is still unbought returns the same line.
    again = await client.post(f"{ITEMS.format(fid=fid)}/{iid}/to-buy")
    assert again.json()["data"]["id"] == buy["id"]
    open_buys = (await client.get(BUYS.format(fid=fid), params={"bought": "false"})).json()["data"]
    assert len(open_buys) == 1


async def test_mark_bought_bumps_linked_stock(client: AsyncClient) -> None:
    fid = await _create_family(client)
    iid = (
        await client.post(ITEMS.format(fid=fid), json={"name": "牛奶", "qty": 0, "low_at": 1})
    ).json()["data"]["id"]
    bid = (await client.post(f"{ITEMS.format(fid=fid)}/{iid}/to-buy")).json()["data"]["id"]

    bought = await client.post(
        f"{BUYS.format(fid=fid)}/{bid}/bought", json={"into_stock_qty": 4}
    )
    assert bought.status_code == 200, bought.text
    assert bought.json()["data"]["bought"] is True

    # No GET-by-id route; read the bumped item back via the list.
    items = (await client.get(ITEMS.format(fid=fid))).json()["data"]
    target = next(i for i in items if i["id"] == iid)
    assert target["qty"] == 4
    assert target["is_low"] is False


async def test_mark_bought_creates_stock_when_unlinked(client: AsyncClient) -> None:
    fid = await _create_family(client)
    bid = (
        await client.post(BUYS.format(fid=fid), json={"name": "可乐", "emoji": "🥤"})
    ).json()["data"]["id"]

    bought = await client.post(
        f"{BUYS.format(fid=fid)}/{bid}/bought", json={"into_stock_qty": 6}
    )
    assert bought.status_code == 200, bought.text
    assert bought.json()["data"]["stock_item_id"] is not None

    items = (await client.get(ITEMS.format(fid=fid))).json()["data"]
    created = next(i for i in items if i["name"] == "可乐")
    assert created["qty"] == 6
    assert created["emoji"] == "🥤"


async def test_mark_bought_without_qty_does_not_touch_stock(client: AsyncClient) -> None:
    fid = await _create_family(client)
    bid = (await client.post(BUYS.format(fid=fid), json={"name": "面包"})).json()["data"]["id"]

    bought = await client.post(f"{BUYS.format(fid=fid)}/{bid}/bought")
    assert bought.status_code == 200
    assert bought.json()["data"]["bought"] is True
    # Nothing flowed into stock.
    assert (await client.get(ITEMS.format(fid=fid))).json()["data"] == []


async def test_reopen_buy(client: AsyncClient) -> None:
    fid = await _create_family(client)
    bid = (await client.post(BUYS.format(fid=fid), json={"name": "茶叶"})).json()["data"]["id"]
    await client.post(f"{BUYS.format(fid=fid)}/{bid}/bought")

    reopened = await client.post(f"{BUYS.format(fid=fid)}/{bid}/reopen")
    assert reopened.status_code == 200
    assert reopened.json()["data"]["bought"] is False
    assert reopened.json()["data"]["bought_at"] is None


async def test_non_member_forbidden(client: AsyncClient) -> None:
    fid = await _create_family(client)
    response = await client.get(ITEMS.format(fid=fid), headers=XIAOBAO)
    assert response.status_code == 404


async def test_preview_prioritises_low_then_buys_then_empty(client: AsyncClient) -> None:
    from app.core.database import async_session_maker
    from app.models.plugin import InstalledPlugin
    from app.plugins.stock.service import preview_hook

    fid = await _create_family(client)
    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="stock")

    # Empty → 充足.
    async with async_session_maker() as session:
        empty = await preview_hook(session, ip, uuid.UUID(LAOCHEN))
    assert empty.primary == "囤货充足"

    # An open buy line → counts it.
    await client.post(BUYS.format(fid=fid), json={"name": "醋"})
    async with async_session_maker() as session:
        with_buy = await preview_hook(session, ip, uuid.UUID(LAOCHEN))
    assert "采买清单" in with_buy.primary
    assert with_buy.badge == "1"

    # A low stock item takes priority over the shopping list.
    await client.post(ITEMS.format(fid=fid), json={"name": "糖", "qty": 0, "low_at": 1})
    async with async_session_maker() as session:
        with_low = await preview_hook(session, ip, uuid.UUID(LAOCHEN))
    assert "要补货" in with_low.primary
    assert with_low.secondary_tone == "warning"
