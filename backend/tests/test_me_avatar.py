import random
from io import BytesIO

from httpx import AsyncClient
from PIL import Image


def _png_bytes(color: str = "red") -> bytes:
    buf = BytesIO()
    Image.new("RGB", (8, 8), color).save(buf, format="PNG")
    return buf.getvalue()


def _random_phone() -> str:
    return "1" + str(random.randint(3, 9)) + "".join(str(random.randint(0, 9)) for _ in range(9))


async def _register_user(client: AsyncClient) -> dict[str, str]:
    """注册新用户，返回鉴权头（X-User-Id）。"""
    res = await client.post(
        "/api/v1/auth/login",
        json={"phone": _random_phone(), "password": "secret123"},
    )
    return {"X-User-Id": res.json()["data"]["user"]["id"]}


async def test_avatar_absent_by_default(client: AsyncClient) -> None:
    headers = await _register_user(client)
    me = await client.get("/api/v1/me", headers=headers)
    user = me.json()["data"]["user"]
    assert user["avatar_version"] == 0
    assert user["avatar_url"] is None


async def test_upload_avatar_sets_url_and_bumps_version(client: AsyncClient) -> None:
    headers = await _register_user(client)

    up = await client.post(
        "/api/v1/me/avatar",
        files={"file": ("a.png", _png_bytes(), "image/png")},
        headers=headers,
    )
    assert up.status_code == 200, up.text
    data = up.json()["data"]
    assert data["avatar_version"] == 1
    assert data["avatar_url"] is not None
    assert "v=1" in data["avatar_url"]

    # /me 也应反映头像。
    me = await client.get("/api/v1/me", headers=headers)
    assert me.json()["data"]["user"]["avatar_url"] is not None

    # 原始字节可读且像 PNG。
    raw = await client.get("/api/v1/me/avatar", headers=headers)
    assert raw.status_code == 200
    assert raw.headers["content-type"] == "image/png"
    assert raw.content[:8] == b"\x89PNG\r\n\x1a\n"

    # 重新上传 version 自增。
    up2 = await client.post(
        "/api/v1/me/avatar",
        files={"file": ("a.png", _png_bytes("blue"), "image/png")},
        headers=headers,
    )
    assert up2.json()["data"]["avatar_version"] == 2


async def test_delete_avatar_falls_back_to_emoji(client: AsyncClient) -> None:
    headers = await _register_user(client)
    await client.post(
        "/api/v1/me/avatar",
        files={"file": ("a.png", _png_bytes(), "image/png")},
        headers=headers,
    )
    deleted = await client.delete("/api/v1/me/avatar", headers=headers)
    assert deleted.status_code == 200
    assert deleted.json()["data"]["avatar_url"] is None

    raw = await client.get("/api/v1/me/avatar", headers=headers)
    assert raw.status_code == 404


async def test_upload_avatar_rejects_non_image(client: AsyncClient) -> None:
    headers = await _register_user(client)
    bad = await client.post(
        "/api/v1/me/avatar",
        files={"file": ("note.txt", b"not an image", "text/plain")},
        headers=headers,
    )
    assert bad.status_code == 400


async def test_get_avatar_404_when_unset(client: AsyncClient) -> None:
    headers = await _register_user(client)
    raw = await client.get("/api/v1/me/avatar", headers=headers)
    assert raw.status_code == 404
