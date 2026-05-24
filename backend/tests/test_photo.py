"""Photo plugin tests — multipart upload, raw bytes, validation, isolation."""

import uuid
from io import BytesIO

import pytest
from httpx import AsyncClient
from PIL import Image

XIAOBAO = {"X-User-Id": "019000a0-1100-7000-8000-000000000003"}


def _unique_name() -> str:
    return f"相册测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


@pytest.fixture
def png_bytes() -> bytes:
    """A small but valid PNG (100x80, solid red)."""
    img = Image.new("RGB", (100, 80), color=(255, 0, 0))
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


# ---- Album CRUD ------------------------------------------------------------


async def test_create_and_list_albums(client: AsyncClient) -> None:
    fid = await _create_family(client)
    create = await client.post(
        f"/api/v1/families/{fid}/plugins/photo/albums",
        json={"name": "2024春节", "description": "回老家拍的"},
    )
    assert create.status_code == 201, create.text
    album = create.json()["data"]
    assert album["name"] == "2024春节"
    assert album["photo_count"] == 0

    listing = await client.get(f"/api/v1/families/{fid}/plugins/photo/albums")
    assert listing.status_code == 200
    names = [a["name"] for a in listing.json()["data"]]
    assert "2024春节" in names


async def test_delete_album(client: AsyncClient) -> None:
    fid = await _create_family(client)
    album = (
        await client.post(
            f"/api/v1/families/{fid}/plugins/photo/albums",
            json={"name": _unique_name()},
        )
    ).json()["data"]

    response = await client.delete(f"/api/v1/families/{fid}/plugins/photo/albums/{album['id']}")
    assert response.status_code == 200

    # Album gone from listing.
    remaining = await client.get(f"/api/v1/families/{fid}/plugins/photo/albums")
    assert album["id"] not in [a["id"] for a in remaining.json()["data"]]


# ---- Photo upload + retrieval ---------------------------------------------


async def test_upload_photo_returns_metadata_and_url(client: AsyncClient, png_bytes: bytes) -> None:
    fid = await _create_family(client)
    response = await client.post(
        f"/api/v1/families/{fid}/plugins/photo/photos",
        files={"file": ("hello.png", png_bytes, "image/png")},
        data={"caption": "你好"},
    )
    assert response.status_code == 201, response.text
    photo = response.json()["data"]
    assert photo["content_type"] == "image/png"
    assert photo["size_bytes"] == len(png_bytes)
    assert photo["width"] == 100
    assert photo["height"] == 80
    assert photo["caption"] == "你好"
    # URL is relative — points at the /raw endpoint for this photo.
    assert photo["url"].endswith(f"/photos/{photo['id']}/raw")


async def test_get_raw_returns_exact_bytes(client: AsyncClient, png_bytes: bytes) -> None:
    fid = await _create_family(client)
    upload = await client.post(
        f"/api/v1/families/{fid}/plugins/photo/photos",
        files={"file": ("a.png", png_bytes, "image/png")},
    )
    photo = upload.json()["data"]

    raw = await client.get(photo["url"])
    assert raw.status_code == 200
    assert raw.headers["content-type"].startswith("image/png")
    assert raw.content == png_bytes


async def test_list_photos_after_upload(client: AsyncClient, png_bytes: bytes) -> None:
    fid = await _create_family(client)
    # Upload two photos.
    await client.post(
        f"/api/v1/families/{fid}/plugins/photo/photos",
        files={"file": ("1.png", png_bytes, "image/png")},
    )
    await client.post(
        f"/api/v1/families/{fid}/plugins/photo/photos",
        files={"file": ("2.png", png_bytes, "image/png")},
    )

    listing = await client.get(f"/api/v1/families/{fid}/plugins/photo/photos")
    assert listing.status_code == 200
    assert len(listing.json()["data"]) == 2


async def test_upload_into_album_increments_count(client: AsyncClient, png_bytes: bytes) -> None:
    fid = await _create_family(client)
    album = (
        await client.post(
            f"/api/v1/families/{fid}/plugins/photo/albums",
            json={"name": _unique_name()},
        )
    ).json()["data"]

    await client.post(
        f"/api/v1/families/{fid}/plugins/photo/photos",
        files={"file": ("a.png", png_bytes, "image/png")},
        data={"album_id": album["id"]},
    )

    refreshed = await client.get(f"/api/v1/families/{fid}/plugins/photo/albums")
    matching = next(a for a in refreshed.json()["data"] if a["id"] == album["id"])
    assert matching["photo_count"] == 1


async def test_delete_photo_removes_metadata(client: AsyncClient, png_bytes: bytes) -> None:
    fid = await _create_family(client)
    upload = await client.post(
        f"/api/v1/families/{fid}/plugins/photo/photos",
        files={"file": ("a.png", png_bytes, "image/png")},
    )
    photo_id = upload.json()["data"]["id"]

    deleted = await client.delete(f"/api/v1/families/{fid}/plugins/photo/photos/{photo_id}")
    assert deleted.status_code == 200

    # Subsequent fetch returns 404.
    get = await client.get(f"/api/v1/families/{fid}/plugins/photo/photos/{photo_id}")
    assert get.status_code == 404


# ---- Validation ------------------------------------------------------------


async def test_upload_non_image_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    response = await client.post(
        f"/api/v1/families/{fid}/plugins/photo/photos",
        files={"file": ("hi.txt", b"hello, world", "image/png")},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_IMAGE"


async def test_upload_empty_file_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    response = await client.post(
        f"/api/v1/families/{fid}/plugins/photo/photos",
        files={"file": ("empty.png", b"", "image/png")},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_IMAGE"


# ---- Data isolation --------------------------------------------------------


async def test_non_member_cannot_see_albums(client: AsyncClient) -> None:
    fid = await _create_family(client)
    response = await client.get(
        f"/api/v1/families/{fid}/plugins/photo/albums",
        headers=XIAOBAO,
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "FAMILY_NOT_FOUND"


async def test_non_member_cannot_fetch_raw_bytes(client: AsyncClient, png_bytes: bytes) -> None:
    fid = await _create_family(client)
    upload = await client.post(
        f"/api/v1/families/{fid}/plugins/photo/photos",
        files={"file": ("a.png", png_bytes, "image/png")},
    )
    photo = upload.json()["data"]

    # 小宝 (not a member) tries to read raw bytes — must be blocked.
    response = await client.get(photo["url"], headers=XIAOBAO)
    assert response.status_code == 404


async def test_upload_to_other_family_album_rejected(client: AsyncClient, png_bytes: bytes) -> None:
    fid_a = await _create_family(client)
    album_a = (
        await client.post(
            f"/api/v1/families/{fid_a}/plugins/photo/albums",
            json={"name": _unique_name()},
        )
    ).json()["data"]

    fid_b = await _create_family(client)
    # Try to upload to family B but tag with album from family A.
    response = await client.post(
        f"/api/v1/families/{fid_b}/plugins/photo/photos",
        files={"file": ("a.png", png_bytes, "image/png")},
        data={"album_id": album_a["id"]},
    )
    assert response.status_code == 404


# ---- Preview ---------------------------------------------------------------


async def test_preview_empty(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "photo"})
    listing = await client.get(f"/api/v1/families/{fid}/plugins")
    preview = listing.json()["data"][0]["preview"]
    assert "还没有照片" in preview["primary"]
    assert preview["color_token"] == "photo"


async def test_preview_after_upload(client: AsyncClient, png_bytes: bytes) -> None:
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "photo"})
    await client.post(
        f"/api/v1/families/{fid}/plugins/photo/photos",
        files={"file": ("a.png", png_bytes, "image/png")},
    )

    listing = await client.get(f"/api/v1/families/{fid}/plugins")
    preview = listing.json()["data"][0]["preview"]
    # Either "本周新照片 · 1" (count > 0) or fallback "共 1 张照片".
    assert "1" in preview["primary"]
    assert "老陈" in preview["secondary"]
