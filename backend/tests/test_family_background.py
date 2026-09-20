"""家庭背景上传、共享权限、缓存刷新与恢复默认。"""

import uuid
from io import BytesIO

import pytest
from httpx import AsyncClient
from PIL import Image

from app.core import storage as storage_module
from app.core.config import settings
from app.core.database import async_session_maker
from app.models.family import Family

MEMBER = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}


def png(color: str = "red") -> bytes:
    out = BytesIO()
    Image.new("RGB", (32, 16), color).save(out, format="PNG")
    return out.getvalue()


async def family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": f"背景-{uuid.uuid4().hex[:6]}"})
    return response.json()["data"]["id"]


async def join(client: AsyncClient, fid: str, role: str = "member") -> None:
    invite = await client.post(
        f"/api/v1/families/{fid}/invitations",
        json={"role": role, "ttl_seconds": 3600, "channel": "link"},
    )
    code = invite.json()["data"]["code"]
    assert (
        await client.post(f"/api/v1/invitations/{code}/accept", headers=MEMBER)
    ).status_code == 200


async def upload(client: AsyncClient, fid: str, color: str = "red", **kwargs):
    return await client.post(
        f"/api/v1/families/{fid}/background",
        files={"file": ("background.png", png(color), "image/png")},
        **kwargs,
    )


async def test_upload_replace_reset_and_bootstrap(client: AsyncClient) -> None:
    fid = await family(client)
    path = f"/api/v1/families/{fid}"
    assert (await client.get(path)).json()["data"]["background_url"] is None
    assert (await client.get(path + "/background")).status_code == 404
    uploaded = await upload(client, fid)
    assert uploaded.status_code == 200, uploaded.text
    url = uploaded.json()["data"]["background_url"]
    assert url == path + "/background?v=1"
    image = await client.get(url)
    assert image.content == png() and image.headers["content-type"] == "image/png"
    assert "private" in image.headers["cache-control"]
    async with async_session_maker() as session:
        row = await session.get(Family, uuid.UUID(fid))
        old_key = row.background_storage_key
    replaced = await upload(client, fid, "blue")
    assert replaced.json()["data"]["background_url"].endswith("v=2")
    assert not await storage_module.storage.exists(old_key)
    assert (await client.get(url)).status_code == 404
    assert (await client.get(path + "/background?v=2")).content == png("blue")
    await client.post(path + "/switch")
    bootstrap = (await client.get("/api/v1/me/bootstrap")).json()["data"]
    assert bootstrap["current_family"]["background_url"].endswith("v=2")
    assert next(f for f in bootstrap["families"] if f["id"] == fid)["background_url"].endswith(
        "v=2"
    )
    deleted = await client.delete(path + "/background")
    assert deleted.status_code == 200 and deleted.json()["data"]["background_url"] is None
    assert (await client.get(path + "/background")).status_code == 404
    again = await upload(client, fid)
    assert again.json()["data"]["background_url"].endswith("v=4")


async def test_family_sharing_and_isolation(client: AsyncClient) -> None:
    fid = await family(client)
    uploaded = await upload(client, fid)
    url = uploaded.json()["data"]["background_url"]
    assert (await client.get(url, headers=MEMBER)).status_code == 404
    assert (await upload(client, fid, headers=MEMBER)).status_code == 404
    assert (await client.delete(url, headers=MEMBER)).status_code == 404
    await join(client, fid)
    assert (await client.get(url, headers=MEMBER)).content == png()
    assert (await upload(client, fid, headers=MEMBER)).status_code == 403
    assert (await client.delete(url, headers=MEMBER)).status_code == 403
    other = await family(client)
    assert (await client.get(f"/api/v1/families/{other}")).json()["data"]["background_url"] is None


async def test_admin_can_change_background(client: AsyncClient) -> None:
    fid = await family(client)
    await join(client, fid, "admin")
    uploaded = await upload(client, fid, headers=MEMBER)
    assert uploaded.status_code == 200
    assert (
        await client.delete(f"/api/v1/families/{fid}/background", headers=MEMBER)
    ).status_code == 200


async def test_invalid_upload_preserves_background(client: AsyncClient, monkeypatch) -> None:
    fid = await family(client)
    uploaded = await upload(client, fid)
    url = uploaded.json()["data"]["background_url"]
    for content in (b"", b"not an image"):
        response = await client.post(
            f"/api/v1/families/{fid}/background",
            files={"file": ("bad.png", content, "image/png")},
        )
        assert response.status_code == 400
    monkeypatch.setattr(settings, "max_upload_bytes", 10)
    response = await upload(client, fid)
    assert response.status_code == 413
    assert (await client.get(url)).content == png()


async def test_storage_failure_preserves_background(client: AsyncClient, monkeypatch) -> None:
    fid = await family(client)
    uploaded = await upload(client, fid)
    url = uploaded.json()["data"]["background_url"]

    async def fail(*args, **kwargs):
        raise OSError("storage unavailable")

    monkeypatch.setattr(storage_module.storage, "put", fail)
    with pytest.raises(OSError):
        await upload(client, fid, "blue")
    assert (await client.get(url)).content == png()
