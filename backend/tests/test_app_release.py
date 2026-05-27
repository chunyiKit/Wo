import pytest
from httpx import AsyncClient

from app.core.config import settings


@pytest.fixture(autouse=True)
def _isolated_release_storage(tmp_path, monkeypatch) -> None:
    """Point release storage at a tmp dir so tests don't touch real releases."""
    monkeypatch.setattr(settings, "storage_root", str(tmp_path))
    monkeypatch.setattr(settings, "app_release_token", "secret-token")


async def test_version_null_when_nothing_published(client: AsyncClient) -> None:
    res = await client.get("/api/v1/app/version")
    assert res.status_code == 200
    assert res.json()["data"] is None


async def test_download_404_when_nothing_published(client: AsyncClient) -> None:
    res = await client.get("/api/v1/app/download")
    assert res.status_code == 404


async def test_publish_then_version_and_download(client: AsyncClient) -> None:
    apk = b"PK\x03\x04" + b"\x00" * 2048  # zip magic + filler
    pub = await client.post(
        "/api/v1/app/release",
        data={"version_name": "0.2.0", "version_code": "3", "notes": "新增检查更新"},
        files={"file": ("wo.apk", apk, "application/vnd.android.package-archive")},
        headers={"X-Release-Token": "secret-token"},
    )
    assert pub.status_code == 200, pub.text
    data = pub.json()["data"]
    assert data["version_name"] == "0.2.0"
    assert data["version_code"] == 3
    assert data["size"] == len(apk)
    assert data["download_url"] == "/api/v1/app/download?v=3"

    ver = await client.get("/api/v1/app/version")
    assert ver.json()["data"]["version_code"] == 3
    assert ver.json()["data"]["notes"] == "新增检查更新"

    dl = await client.get("/api/v1/app/download")
    assert dl.status_code == 200
    assert dl.content == apk
    assert dl.headers["content-type"] == "application/vnd.android.package-archive"


async def test_publish_replaces_previous_release(client: AsyncClient) -> None:
    for code, body in ((1, b"PK\x03\x04old"), (2, b"PK\x03\x04new-build")):
        await client.post(
            "/api/v1/app/release",
            data={"version_name": f"0.{code}.0", "version_code": str(code)},
            files={"file": ("wo.apk", body, "application/octet-stream")},
            headers={"X-Release-Token": "secret-token"},
        )
    ver = await client.get("/api/v1/app/version")
    assert ver.json()["data"]["version_code"] == 2
    dl = await client.get("/api/v1/app/download")
    assert dl.content == b"PK\x03\x04new-build"


async def test_publish_rejects_wrong_token(client: AsyncClient) -> None:
    res = await client.post(
        "/api/v1/app/release",
        data={"version_name": "0.2.0", "version_code": "3"},
        files={"file": ("wo.apk", b"PK\x03\x04", "application/octet-stream")},
        headers={"X-Release-Token": "wrong"},
    )
    assert res.status_code == 401


async def test_publish_rejects_missing_token(client: AsyncClient) -> None:
    res = await client.post(
        "/api/v1/app/release",
        data={"version_name": "0.2.0", "version_code": "3"},
        files={"file": ("wo.apk", b"PK\x03\x04", "application/octet-stream")},
    )
    assert res.status_code == 401


async def test_publish_disabled_when_token_unset(client: AsyncClient, monkeypatch) -> None:
    monkeypatch.setattr(settings, "app_release_token", "")
    res = await client.post(
        "/api/v1/app/release",
        data={"version_name": "0.2.0", "version_code": "3"},
        files={"file": ("wo.apk", b"PK\x03\x04", "application/octet-stream")},
        headers={"X-Release-Token": "anything"},
    )
    assert res.status_code == 403
