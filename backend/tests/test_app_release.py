import json
from pathlib import Path

import pytest
from httpx import AsyncClient

from app.core.config import settings


@pytest.fixture(autouse=True)
def _isolated_release_storage(tmp_path, monkeypatch) -> None:
    """Point release storage at a tmp dir so tests don't touch real releases.

    Also blanks the COS settings so the local-disk fallback path is exercised
    by default; the COS-mode tests opt in by re-setting them + patching the
    client factory.
    """
    monkeypatch.setattr(settings, "storage_root", str(tmp_path))
    monkeypatch.setattr(settings, "app_release_token", "secret-token")
    monkeypatch.setattr(settings, "cos_bucket", "")
    monkeypatch.setattr(settings, "cos_region", "")
    monkeypatch.setattr(settings, "cos_secret_id", "")
    monkeypatch.setattr(settings, "cos_secret_key", "")


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


# ---- COS-mode tests --------------------------------------------------------
#
# We don't hit real COS in tests. Instead we plug in a fake CosClient via
# monkeypatch, verify publish() called put_object with the right key/content,
# and verify /version + /download surface the COS URL the way the app expects.


class _FakeCos:
    """Records put_object calls + reads back the temp file we received."""

    def __init__(self) -> None:
        self.puts: list[tuple[str, bytes, str]] = []

    def put_object(self, key: str, local_path: Path, content_type: str) -> None:
        self.puts.append((key, local_path.read_bytes(), content_type))

    def public_url(self, key: str) -> str:
        return f"https://fake-bucket.cos.ap-shanghai.myqcloud.com/{key}"


@pytest.fixture
def _cos_mode(monkeypatch, tmp_path) -> _FakeCos:
    """Switch the publish flow into COS mode with a fake client."""
    monkeypatch.setattr(settings, "cos_bucket", "fake-bucket")
    monkeypatch.setattr(settings, "cos_region", "ap-shanghai")
    monkeypatch.setattr(settings, "cos_secret_id", "id")
    monkeypatch.setattr(settings, "cos_secret_key", "key")
    monkeypatch.setattr(settings, "cos_apk_prefix", "app-release")

    fake = _FakeCos()
    # Patch the symbol the service module actually calls — replacing the
    # factory in app.core.cos alone wouldn't help because app_release imports
    # `get_cos_client` by name into its own namespace.
    from app.services import app_release as svc

    monkeypatch.setattr(svc, "get_cos_client", lambda: fake)
    return fake


async def test_cos_publish_uploads_and_returns_public_url(
    client: AsyncClient, _cos_mode: _FakeCos, tmp_path
) -> None:
    apk = b"PK\x03\x04" + b"\x00" * 1024
    pub = await client.post(
        "/api/v1/app/release",
        data={"version_name": "0.3.0", "version_code": "5", "notes": "上 COS"},
        files={"file": ("wo.apk", apk, "application/vnd.android.package-archive")},
        headers={"X-Release-Token": "secret-token"},
    )
    assert pub.status_code == 200, pub.text
    data = pub.json()["data"]

    # put_object called exactly once with the version-stamped key + full body.
    assert len(_cos_mode.puts) == 1
    key, body, content_type = _cos_mode.puts[0]
    assert key == "app-release/wo-5.bin"
    assert body == apk
    # Uploaded as octet-stream to bypass Tencent Cloud's DownloadForbidden
    # filter; the App installs by local content-type, not remote.
    assert content_type == "application/octet-stream"

    # download_url is the COS public URL, not the relative path.
    assert data["download_url"] == (
        "https://fake-bucket.cos.ap-shanghai.myqcloud.com/app-release/wo-5.bin"
    )

    # /version surfaces the same URL on the next read.
    ver = await client.get("/api/v1/app/version")
    assert ver.json()["data"]["download_url"] == data["download_url"]

    # Manifest persisted the storage marker so a process restart keeps the
    # COS-mode behaviour even without re-publishing.
    manifest_raw = json.loads(
        (Path(settings.storage_root) / "app-release" / "manifest.json").read_text(
            encoding="utf-8"
        )
    )
    assert manifest_raw["storage"] == "cos"
    assert manifest_raw["cos_url"].endswith("/app-release/wo-5.bin")

    # No local APK left on disk in COS mode — bandwidth offload is the point.
    assert not (Path(settings.storage_root) / "app-release" / "wo-release.apk").exists()


async def test_cos_download_endpoint_redirects_to_cos(
    client: AsyncClient, _cos_mode: _FakeCos
) -> None:
    # Publish in COS mode first.
    await client.post(
        "/api/v1/app/release",
        data={"version_name": "0.3.0", "version_code": "5"},
        files={"file": ("wo.apk", b"PK\x03\x04xx", "application/octet-stream")},
        headers={"X-Release-Token": "secret-token"},
    )

    # The legacy /download path should 302 to COS so any old client with the
    # relative URL baked in still gets the new APK.
    dl = await client.get("/api/v1/app/download", follow_redirects=False)
    assert dl.status_code == 302
    assert dl.headers["location"] == (
        "https://fake-bucket.cos.ap-shanghai.myqcloud.com/app-release/wo-5.bin"
    )
