"""Plant journal plugin tests — plant CRUD, care-log upload (photo persists
independent of AI), care-cycle arming, adopting AI suggestions, and settings."""

import io
import uuid

from httpx import AsyncClient
from PIL import Image

from app.core.database import async_session_maker
from app.plugins.plant.models import PlantLog

BASE = "/api/v1/families/{fid}/plugins/plant"


def _jpeg_bytes(color: str = "green") -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (16, 16), color).save(buf, format="JPEG")
    return buf.getvalue()


async def _create_family(client: AsyncClient) -> str:
    resp = await client.post(
        "/api/v1/families", json={"name": f"植物测试-{uuid.uuid4().hex[:6]}"}
    )
    return resp.json()["data"]["id"]


async def _create_plant(client: AsyncClient, fid: str, **extra) -> dict:
    body = {"name": "绿萝", **extra}
    resp = await client.post(f"{BASE.format(fid=fid)}/plants", json=body)
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]


# ---- plant CRUD ------------------------------------------------------------


async def test_create_and_list_plant(client: AsyncClient) -> None:
    fid = await _create_family(client)
    created = await _create_plant(client, fid, species="绿萝", placement="阳台")
    assert created["name"] == "绿萝"
    assert created["placement"] == "阳台"
    assert created["cover_url"] is None

    listed = await client.get(f"{BASE.format(fid=fid)}/plants")
    assert listed.status_code == 200
    assert len(listed.json()["data"]) == 1


async def test_empty_name_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    resp = await client.post(f"{BASE.format(fid=fid)}/plants", json={"name": "  "})
    assert resp.status_code == 400


async def test_setting_interval_arms_due_date(client: AsyncClient) -> None:
    fid = await _create_family(client)
    plant = await _create_plant(client, fid)
    assert plant["next_water_due"] is None

    updated = await client.put(
        f"{BASE.format(fid=fid)}/plants/{plant['id']}",
        json={"water_interval_days": 5},
    )
    assert updated.status_code == 200
    assert updated.json()["data"]["next_water_due"] is not None


async def test_delete_plant(client: AsyncClient) -> None:
    fid = await _create_family(client)
    plant = await _create_plant(client, fid)
    resp = await client.delete(f"{BASE.format(fid=fid)}/plants/{plant['id']}")
    assert resp.status_code == 200
    listed = await client.get(f"{BASE.format(fid=fid)}/plants")
    assert listed.json()["data"] == []


# ---- care logs (photo persistence) -----------------------------------------


async def test_create_log_persists_photo_independent_of_ai(client: AsyncClient) -> None:
    """A care log's photo is persisted and servable; the record survives even if
    AI analysis (unconfigured in tests) fails."""
    fid = await _create_family(client)
    plant = await _create_plant(client, fid)

    resp = await client.post(
        f"{BASE.format(fid=fid)}/plants/{plant['id']}/logs",
        files={"file": ("p.jpg", _jpeg_bytes(), "image/jpeg")},
        data={"note": "新长了一片叶子"},
    )
    assert resp.status_code == 201, resp.text
    log = resp.json()["data"]
    assert log["note"] == "新长了一片叶子"
    assert log["photo_url"] is not None
    # The POST response reflects the freshly-created row.
    assert log["ai_status"] in {"pending", "ready", "failed"}

    # The record persists and the photo is servable regardless of AI outcome.
    listed = await client.get(f"{BASE.format(fid=fid)}/plants/{plant['id']}/logs")
    assert len(listed.json()["data"]) == 1

    photo = await client.get(
        f"{BASE.format(fid=fid)}/plants/{plant['id']}/logs/{log['id']}/photo"
    )
    assert photo.status_code == 200
    assert photo.headers["content-type"].startswith("image/")


async def test_first_log_sets_plant_cover(client: AsyncClient) -> None:
    fid = await _create_family(client)
    plant = await _create_plant(client, fid)
    await client.post(
        f"{BASE.format(fid=fid)}/plants/{plant['id']}/logs",
        files={"file": ("p.jpg", _jpeg_bytes(), "image/jpeg")},
    )
    got = await client.get(f"{BASE.format(fid=fid)}/plants/{plant['id']}")
    assert got.json()["data"]["cover_url"] is not None


async def test_non_image_upload_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    plant = await _create_plant(client, fid)
    resp = await client.post(
        f"{BASE.format(fid=fid)}/plants/{plant['id']}/logs",
        files={"file": ("x.txt", b"not an image", "text/plain")},
    )
    assert resp.status_code == 400


# ---- adopt AI suggestion ---------------------------------------------------


async def test_adopt_suggestion_sets_interval_and_arms(client: AsyncClient) -> None:
    fid = await _create_family(client)
    plant = await _create_plant(client, fid)
    log_resp = await client.post(
        f"{BASE.format(fid=fid)}/plants/{plant['id']}/logs",
        files={"file": ("p.jpg", _jpeg_bytes(), "image/jpeg")},
    )
    log_id = log_resp.json()["data"]["id"]

    # Simulate the AI having produced a suggestion (analysis is unconfigured in
    # tests, so set the suggested value directly on the row).
    async with async_session_maker() as session:
        row = await session.get(PlantLog, uuid.UUID(log_id))
        row.ai_suggested_water_days = 7
        session.add(row)
        await session.commit()

    adopt = await client.post(
        f"{BASE.format(fid=fid)}/plants/{plant['id']}/logs/{log_id}/adopt",
        json={"water": True, "fert": False},
    )
    assert adopt.status_code == 200, adopt.text
    data = adopt.json()["data"]
    assert data["water_interval_days"] == 7
    assert data["next_water_due"] is not None


async def test_adopt_without_suggestion_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    plant = await _create_plant(client, fid)
    log_resp = await client.post(
        f"{BASE.format(fid=fid)}/plants/{plant['id']}/logs",
        files={"file": ("p.jpg", _jpeg_bytes(), "image/jpeg")},
    )
    log_id = log_resp.json()["data"]["id"]
    adopt = await client.post(
        f"{BASE.format(fid=fid)}/plants/{plant['id']}/logs/{log_id}/adopt",
        json={"water": True, "fert": True},
    )
    assert adopt.status_code == 400


# ---- family default environment --------------------------------------------


async def test_settings_roundtrip(client: AsyncClient) -> None:
    fid = await _create_family(client)
    empty = await client.get(f"{BASE.format(fid=fid)}/settings")
    assert empty.status_code == 200
    assert empty.json()["data"]["latitude"] is None

    put = await client.put(
        f"{BASE.format(fid=fid)}/settings",
        json={"latitude": 31.2304, "longitude": 121.4737, "location_label": "上海"},
    )
    assert put.status_code == 200
    assert put.json()["data"]["location_label"] == "上海"

    got = await client.get(f"{BASE.format(fid=fid)}/settings")
    assert got.json()["data"]["latitude"] == 31.2304


# ---- membership isolation --------------------------------------------------


async def test_other_family_cannot_access(client: AsyncClient) -> None:
    fid = await _create_family(client)
    plant = await _create_plant(client, fid)
    # A random (non-member) family id in the path → 403/404.
    other = uuid.uuid4()
    resp = await client.get(
        f"/api/v1/families/{other}/plugins/plant/plants/{plant['id']}"
    )
    assert resp.status_code in (403, 404)
