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


async def _family(client: AsyncClient) -> str:
    resp = await client.post(
        "/api/v1/families", json={"name": f"测试-{uuid.uuid4().hex[:6]}"}
    )
    return resp.json()["data"]["id"]


async def _create(client: AsyncClient, fid: str, place: str | None = None) -> dict:
    data = {"city_name": "上海", "city_lng": "121.47", "city_lat": "31.23",
            "caption": "外滩夜色"}
    if place is not None:
        data["place"] = place
    resp = await client.post(
        BASE.format(fid=fid) + "/trips",
        files={"file": ("p.jpg", _jpeg(), "image/jpeg")},
        data=data,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]


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
