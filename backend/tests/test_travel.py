"""Travel plugin tests — create+place, background restyle (replace), retry, delete.

The background generation calls the family's image model; tests monkeypatch
`app.plugins.travel.service.ai_generate_image` so no real provider is hit, and
drive `generate_for_trip` directly for deterministic assertions.
"""

import io
import uuid

import pytest
from httpx import AsyncClient
from PIL import Image

from app.plugins.travel import service as travel_service
from app.plugins.travel.service import generate_for_trip

BASE = "/api/v1/families/{fid}/plugins/travel"
MEM_BASE = "/api/v1/families/{fid}/plugins/memory/memories"
# Seed users (see app/core/seed.py): 老陈 is the default actor; 小林 joins.
XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}


def _jpeg(color: str = "teal") -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (32, 24), color).save(buf, format="JPEG")
    return buf.getvalue()


@pytest.fixture(autouse=True)
def _fake_image_gen(monkeypatch):
    """Background generation returns a fake image instead of calling a provider."""

    async def _fake(**_kwargs):
        return _jpeg("orange"), "image/png"

    monkeypatch.setattr(travel_service, "ai_generate_image", _fake)


async def _create(
    client: AsyncClient,
    fid: str,
    place: str | None = None,
    memory_id: str | None = None,
) -> dict:
    data = {"city_name": "上海", "city_lng": "121.47", "city_lat": "31.23",
            "caption": "外滩夜色"}
    if place is not None:
        data["place"] = place
    if memory_id is not None:
        data["memory_id"] = memory_id
    resp = await client.post(
        BASE.format(fid=fid) + "/trips",
        files={"file": ("p.jpg", _jpeg(), "image/jpeg")},
        data=data,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]


async def _family(client: AsyncClient, with_xiaolin: bool = False) -> str:
    resp = await client.post(
        "/api/v1/families", json={"name": f"测试-{uuid.uuid4().hex[:6]}"}
    )
    fid = resp.json()["data"]["id"]
    if with_xiaolin:
        invite = await client.post(
            f"/api/v1/families/{fid}/invitations",
            json={"role": "member", "ttl_seconds": 3600, "channel": "link"},
        )
        code = invite.json()["data"]["code"]
        await client.post(f"/api/v1/invitations/{code}/accept", headers=XIAOLIN)
    return fid


async def _memory(
    client: AsyncClient,
    fid: str,
    *,
    title: str = "外滩漫步",
    location: str | None = "上海外滩",
    visibility: str = "family",
    headers: dict | None = None,
) -> dict:
    resp = await client.post(
        MEM_BASE.format(fid=fid),
        json={
            "title": title,
            "location": location,
            "visibility": visibility,
            "event_date": "2026-05-25",
        },
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]


async def _set_memory(
    client: AsyncClient, fid: str, trip_id: str, memory_id: str | None,
    headers: dict | None = None,
):
    return await client.put(
        BASE.format(fid=fid) + f"/trips/{trip_id}/memory",
        json={"memory_id": memory_id},
        headers=headers,
    )


async def test_create_with_place(client: AsyncClient) -> None:
    fid = await _family(client)
    trip = await _create(client, fid, place="东方明珠")
    assert trip["city_name"] == "上海"
    assert trip["place"] == "东方明珠"
    assert trip["ai_status"] == "generating"  # response snapshot before background
    assert "/image?v=" in trip["image_url"]  # cache-busting version present


async def test_list(client: AsyncClient) -> None:
    fid = await _family(client)
    await _create(client, fid)
    got = await client.get(BASE.format(fid=fid) + "/trips")
    assert got.status_code == 200
    assert len(got.json()["data"]) == 1


async def test_generate_replaces_and_marks_ready(client: AsyncClient) -> None:
    fid = await _family(client)
    trip = await _create(client, fid, place="长江大桥")
    await generate_for_trip(uuid.UUID(trip["id"]))

    got = await client.get(BASE.format(fid=fid) + "/trips")
    row = got.json()["data"][0]
    assert row["ai_status"] == "ready"
    # the (now AI) image is servable
    img = await client.get(BASE.format(fid=fid) + f"/trips/{trip['id']}/image")
    assert img.status_code == 200
    assert img.headers["content-type"].startswith("image/")


async def test_generate_failure_keeps_failed(client: AsyncClient, monkeypatch) -> None:
    async def _boom(**_kwargs):
        raise RuntimeError("provider down")

    monkeypatch.setattr(travel_service, "ai_generate_image", _boom)
    fid = await _family(client)
    trip = await _create(client, fid)
    await generate_for_trip(uuid.UUID(trip["id"]))

    got = await client.get(BASE.format(fid=fid) + "/trips")
    assert got.json()["data"][0]["ai_status"] == "failed"
    # original still served (we kept it on failure)
    img = await client.get(BASE.format(fid=fid) + f"/trips/{trip['id']}/image")
    assert img.status_code == 200


async def test_retry(client: AsyncClient) -> None:
    fid = await _family(client)
    trip = await _create(client, fid)
    resp = await client.post(BASE.format(fid=fid) + f"/trips/{trip['id']}/retry")
    assert resp.status_code == 200
    assert resp.json()["data"]["ai_status"] == "generating"


async def test_delete(client: AsyncClient) -> None:
    fid = await _family(client)
    trip = await _create(client, fid)
    resp = await client.delete(BASE.format(fid=fid) + f"/trips/{trip['id']}")
    assert resp.status_code == 200
    got = await client.get(BASE.format(fid=fid) + "/trips")
    assert got.json()["data"] == []


# ── 旅行 ↔ 回忆 关联 ──────────────────────────────────────────────


async def test_create_with_memory_link(client: AsyncClient) -> None:
    fid = await _family(client)
    mem = await _memory(client, fid, title="外滩漫步")
    trip = await _create(client, fid, memory_id=mem["id"])
    assert trip["memory_id"] == mem["id"]
    assert trip["memory"]["title"] == "外滩漫步"
    assert trip["memory"]["event_date"] == "2026-05-25"
    assert trip["memory"]["cover_url"] is None  # no media uploaded


async def test_set_and_clear_memory(client: AsyncClient) -> None:
    fid = await _family(client)
    mem = await _memory(client, fid)
    trip = await _create(client, fid)
    assert trip["memory_id"] is None

    linked = await _set_memory(client, fid, trip["id"], mem["id"])
    assert linked.status_code == 200, linked.text
    assert linked.json()["data"]["memory_id"] == mem["id"]
    assert linked.json()["data"]["memory"]["title"] == mem["title"]

    cleared = await _set_memory(client, fid, trip["id"], None)
    assert cleared.status_code == 200
    assert cleared.json()["data"]["memory_id"] is None
    assert cleared.json()["data"]["memory"] is None


async def test_link_other_family_memory_rejected(client: AsyncClient) -> None:
    fid_a = await _family(client)
    fid_b = await _family(client)
    mem_a = await _memory(client, fid_a)
    trip_b = await _create(client, fid_b)

    # PUT a cross-family memory → 404, link unchanged.
    resp = await _set_memory(client, fid_b, trip_b["id"], mem_a["id"])
    assert resp.status_code == 404

    # Create with a cross-family memory_id → silently ignored (stays unlinked).
    trip2 = await _create(client, fid_b, memory_id=mem_a["id"])
    assert trip2["memory_id"] is None


async def test_deleting_memory_unlinks_trip(client: AsyncClient) -> None:
    fid = await _family(client)
    mem = await _memory(client, fid)
    trip = await _create(client, fid, memory_id=mem["id"])
    assert trip["memory_id"] == mem["id"]

    await client.delete(MEM_BASE.format(fid=fid) + f"/{mem['id']}")

    got = await client.get(BASE.format(fid=fid) + "/trips")
    assert got.json()["data"][0]["memory_id"] is None  # FK SET NULL


async def test_private_memory_hidden_from_non_author(client: AsyncClient) -> None:
    fid = await _family(client, with_xiaolin=True)
    # 小林 records a private memory and links 老陈's trip to it.
    mem = await _memory(
        client, fid, title="悄悄话", visibility="private", headers=XIAOLIN
    )
    trip = await _create(client, fid)
    linked = await _set_memory(client, fid, trip["id"], mem["id"], headers=XIAOLIN)
    assert linked.status_code == 200, linked.text

    # 老陈 (non-author) must not see the private memory's title — reads unlinked.
    as_laochen = await client.get(BASE.format(fid=fid) + "/trips")
    row = as_laochen.json()["data"][0]
    assert row["memory_id"] is None
    assert row["memory"] is None

    # 小林 (author) sees the link.
    as_xiaolin = await client.get(
        BASE.format(fid=fid) + "/trips", headers=XIAOLIN
    )
    row2 = as_xiaolin.json()["data"][0]
    assert row2["memory_id"] == mem["id"]
    assert row2["memory"]["title"] == "悄悄话"
