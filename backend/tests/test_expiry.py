"""Expiry (到期管家) tests — CRUD, validation, ordering, days_until, preview."""

import uuid
from datetime import date, timedelta

from httpx import AsyncClient

from app.plugins.expiry.models import ALLOWED_KINDS, ExpiryItem
from app.plugins.expiry.service import build_read

BASE = "/api/v1/families/{fid}/plugins/expiry/items"


async def _create_family(client: AsyncClient) -> str:
    resp = await client.post("/api/v1/families", json={"name": f"测试-{uuid.uuid4().hex[:6]}"})
    return resp.json()["data"]["id"]


async def _create_item(client: AsyncClient, fid: str, **overrides) -> dict:
    body = {
        "name": "护照",
        "emoji": "📘",
        "kind": "passport",
        "expire_on": (date.today() + timedelta(days=40)).isoformat(),
        "notify_enabled": True,
        "notify_days_before": 30,
        "active": True,
    }
    body.update(overrides)
    resp = await client.post(BASE.format(fid=fid), json=body)
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]


# ---- CRUD ------------------------------------------------------------------


async def test_create_and_list(client: AsyncClient) -> None:
    fid = await _create_family(client)
    item = await _create_item(client, fid)
    assert item["name"] == "护照"
    assert item["kind"] == "passport"
    assert item["days_until"] == 40

    resp = await client.get(BASE.format(fid=fid))
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert len(data) == 1
    assert data[0]["id"] == item["id"]


async def test_list_orders_active_first_then_soonest(client: AsyncClient) -> None:
    fid = await _create_family(client)
    far = await _create_item(
        client, fid, name="合同", expire_on=(date.today() + timedelta(days=90)).isoformat()
    )
    near = await _create_item(
        client, fid, name="车险", expire_on=(date.today() + timedelta(days=5)).isoformat()
    )
    paused = await _create_item(
        client,
        fid,
        name="会员卡",
        expire_on=(date.today() + timedelta(days=1)).isoformat(),
        active=False,
    )
    resp = await client.get(BASE.format(fid=fid))
    ids = [r["id"] for r in resp.json()["data"]]
    # active items first (soonest first), paused last regardless of date.
    assert ids == [near["id"], far["id"], paused["id"]]


async def test_filter_by_active(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _create_item(client, fid, name="A")
    await _create_item(client, fid, name="B", active=False)
    resp = await client.get(BASE.format(fid=fid), params={"active": True})
    data = resp.json()["data"]
    assert [r["name"] for r in data] == ["A"]


async def test_update_item(client: AsyncClient) -> None:
    fid = await _create_family(client)
    item = await _create_item(client, fid)
    resp = await client.put(
        f"{BASE.format(fid=fid)}/{item['id']}",
        json={"name": "新护照", "notify_days_before": 60},
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["name"] == "新护照"
    assert data["notify_days_before"] == 60


async def test_delete_item(client: AsyncClient) -> None:
    fid = await _create_family(client)
    item = await _create_item(client, fid)
    resp = await client.delete(f"{BASE.format(fid=fid)}/{item['id']}")
    assert resp.status_code == 200
    resp = await client.get(BASE.format(fid=fid))
    assert resp.json()["data"] == []


# ---- every kind code persists (regression: kind column was varchar(16)) -----


async def test_all_kinds_create_ok(client: AsyncClient) -> None:
    """Every built-in kind code must fit the column. `vehicle_inspection` (18
    chars) used to overflow varchar(16) and 500 on insert."""
    fid = await _create_family(client)
    for kind in ALLOWED_KINDS:
        item = await _create_item(client, fid, name=f"x-{kind}", kind=kind)
        assert item["kind"] == kind
    # And they all read back without truncation.
    resp = await client.get(BASE.format(fid=fid))
    assert resp.status_code == 200
    kinds_back = {r["kind"] for r in resp.json()["data"]}
    assert set(ALLOWED_KINDS) <= kinds_back


# ---- validation ------------------------------------------------------------


async def test_blank_name_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    resp = await client.post(
        BASE.format(fid=fid),
        json={
            "name": "   ",
            "expire_on": date.today().isoformat(),
        },
    )
    assert resp.status_code == 400


async def test_unknown_kind_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    resp = await client.post(
        BASE.format(fid=fid),
        json={
            "name": "X",
            "kind": "not_a_kind",
            "expire_on": date.today().isoformat(),
        },
    )
    assert resp.status_code == 422


async def test_notify_days_before_out_of_range_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    resp = await client.post(
        BASE.format(fid=fid),
        json={
            "name": "X",
            "expire_on": date.today().isoformat(),
            "notify_days_before": 9999,
        },
    )
    assert resp.status_code == 422


async def test_other_family_item_not_found(client: AsyncClient) -> None:
    fid = await _create_family(client)
    item = await _create_item(client, fid)
    other = await _create_family(client)
    resp = await client.get(f"/api/v1/families/{other}/plugins/expiry/items")
    assert resp.json()["data"] == []
    resp = await client.put(
        f"/api/v1/families/{other}/plugins/expiry/items/{item['id']}",
        json={"name": "x"},
    )
    assert resp.status_code == 404


# ---- service: build_read days_until ----------------------------------------


def test_build_read_days_until_negative_when_overdue() -> None:
    row = ExpiryItem(
        family_id=uuid.uuid4(),
        name="过期证",
        expire_on=date.today() - timedelta(days=3),
    )
    read = build_read(row)
    assert read.days_until == -3
