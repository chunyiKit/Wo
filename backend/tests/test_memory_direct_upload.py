"""Direct-to-COS upload: presign (D2) + commit (D3).

The storage backend in tests is whatever is configured locally (LocalStorage),
so every test injects a fake. Two fake shapes matter:

- `FakeDirectStorage` implements the direct-upload capability — the happy path.
- `FakeProxyOnlyStorage` deliberately doesn't, to prove the endpoints degrade
  to 501 instead of handing back a broken ticket.
"""

import base64
import json
import uuid
from datetime import UTC, datetime
from io import BytesIO

import pytest
from httpx import AsyncClient
from PIL import Image

from app.core.storage import BlobStat, PresignedPost, build_post_policy, sign_post_policy

# Seed users (see app/core/seed.py): 老陈 owns by default, 小林 joins.
XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}

MEM_BASE = "/api/v1/families/{fid}/plugins/memory/memories"

PHOTO_MB = 20
VIDEO_MB = 100


class FakeDirectStorage:
    """Presign-capable backend that also remembers what was "uploaded"."""

    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}
        self.tickets: list[tuple[str, str, int]] = []  # (key, content_type, max_bytes)
        self.forced_size: int | None = None

    async def put(self, key: str, data: bytes, content_type: str) -> None:
        self.objects[key] = data

    async def get(self, key: str) -> bytes:
        if key not in self.objects:
            raise FileNotFoundError(key)
        return self.objects[key]

    async def delete(self, key: str) -> None:
        self.objects.pop(key, None)

    async def exists(self, key: str) -> bool:
        return key in self.objects

    async def presigned_post(
        self,
        key: str,
        *,
        content_type: str,
        max_bytes: int,
        ttl_seconds: int,
    ) -> PresignedPost:
        self.tickets.append((key, content_type, max_bytes))
        return PresignedPost(
            url="https://cos.example.com/",
            fields={
                "key": key,
                "acl": "private",
                "Content-Type": content_type,
                "policy": base64.b64encode(b"{}").decode(),
            },
            max_bytes=max_bytes,
            expires_at=datetime.now(UTC),
        )

    async def stat(self, key: str) -> BlobStat | None:
        data = self.objects.get(key)
        if data is None:
            return None
        return BlobStat(
            size_bytes=self.forced_size if self.forced_size is not None else len(data),
            content_type="application/octet-stream",
            head=data[:16],
        )


class FakeProxyOnlyStorage:
    """A backend with no direct-upload capability at all — i.e. local disk.

    Deliberately does **not** subclass the fake above: the capability check is
    `isinstance(..., DirectUploadStorage)`, which only looks at whether the
    methods exist, so inheriting them would silently make this test pass.
    """

    def __init__(self) -> None:
        self.objects: dict[str, bytes] = {}

    async def put(self, key: str, data: bytes, content_type: str) -> None:
        self.objects[key] = data

    async def get(self, key: str) -> bytes:
        if key not in self.objects:
            raise FileNotFoundError(key)
        return self.objects[key]

    async def delete(self, key: str) -> None:
        self.objects.pop(key, None)

    async def exists(self, key: str) -> bool:
        return key in self.objects


@pytest.fixture
def direct(monkeypatch: pytest.MonkeyPatch) -> FakeDirectStorage:
    fake = FakeDirectStorage()
    monkeypatch.setattr("app.plugins.memory.routes.storage", fake)
    return fake


@pytest.fixture
def proxy_only(monkeypatch: pytest.MonkeyPatch) -> FakeProxyOnlyStorage:
    fake = FakeProxyOnlyStorage()
    monkeypatch.setattr("app.plugins.memory.routes.storage", fake)
    return fake


def _png() -> bytes:
    img = Image.new("RGB", (120, 90), color=(40, 120, 200))
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _mp4_head() -> bytes:
    # Minimal ISO base-media prefix: 4-byte box size, then `ftyp`, then brand.
    return b"\x00\x00\x00\x18ftypmp42" + b"\x00" * 32


def _unique_name() -> str:
    return f"直传测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


async def _create_memory(client: AsyncClient, fid: str) -> str:
    response = await client.post(
        MEM_BASE.format(fid=fid),
        json={"title": _unique_name(), "event_date": "2026-05-25"},
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]["id"]


def _presign_url(fid: str, mid: str) -> str:
    return f"{MEM_BASE.format(fid=fid)}/{mid}/media/presign"


def _commit_url(fid: str, mid: str) -> str:
    return f"{MEM_BASE.format(fid=fid)}/{mid}/media/commit"


async def _ticket(client: AsyncClient, fid: str, mid: str, **body: object) -> dict:
    response = await client.post(_presign_url(fid, mid), json=body)
    assert response.status_code == 200, response.text
    return response.json()["data"]


# ---- Signature / policy ----------------------------------------------------


def test_post_policy_signature_is_a_known_answer():
    """Guard the exact COS algorithm: SHA1(policy) replaces the HttpString.

    A wrong variant here (e.g. reusing the request-signature format) fails only
    at COS with an opaque 403, so pin it with a fixed vector.
    """
    policy = '{"expiration":"x","conditions":[{"acl":"private"}]}'
    signature = sign_post_policy(policy, "secret", "1700000000;1700001800")
    assert signature == "3c43b991f0f706de69932453cf415ff598fef438"
    # Any change to the signed inputs must change the signature.
    assert sign_post_policy(policy + " ", "secret", "1700000000;1700001800") != signature
    assert sign_post_policy(policy, "other", "1700000000;1700001800") != signature


def test_policy_locks_everything_that_matters():
    """The ticket must not be usable for anything but the intended object."""
    policy = json.loads(
        build_post_policy(
            bucket="wo-app-1258101097",
            secret_id="AKIDEXAMPLE",
            key="memory/f/m/p.jpg",
            content_type="image/jpeg",
            max_bytes=20 * 1024 * 1024,
            key_time="1700000000;1700001800",
            expiration="2026-01-01T00:00:00.000Z",
        )
    )
    assert policy["expiration"] == "2026-01-01T00:00:00.000Z"
    conditions = {json.dumps(c) for c in policy["conditions"]}
    # Private even though the bucket itself is public-read for the APK flow.
    assert json.dumps({"acl": "private"}) in conditions
    assert json.dumps(["eq", "$key", "memory/f/m/p.jpg"]) in conditions
    assert json.dumps(["eq", "$Content-Type", "image/jpeg"]) in conditions
    assert json.dumps(["content-length-range", 1, 20 * 1024 * 1024]) in conditions
    assert json.dumps({"q-sign-algorithm": "sha1"}) in conditions


# ---- Presign --------------------------------------------------------------


async def test_presign_pins_key_type_and_size(client: AsyncClient, direct: FakeDirectStorage):
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)
    media_id = str(uuid.uuid4())

    ticket = await _ticket(
        client, fid, mid, content_type="image/jpeg", client_id=media_id
    )

    assert ticket["media_id"] == media_id
    assert ticket["key"] == f"memory/{fid}/{mid}/{media_id}.jpg"
    assert ticket["max_bytes"] == PHOTO_MB * 1024 * 1024
    assert ticket["file_field"] == "file"
    assert ticket["fields"]["key"] == ticket["key"]
    assert ticket["url"].startswith("https://")

    # The cap follows the declared kind: videos get the generous limit.
    video = await _ticket(client, fid, mid, content_type="video/mp4")
    assert video["key"].endswith(".mp4")
    assert video["max_bytes"] == VIDEO_MB * 1024 * 1024


async def test_presign_rejects_unsupported_type(client: AsyncClient, direct: FakeDirectStorage):
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)

    response = await client.post(
        _presign_url(fid, mid), json={"content_type": "application/pdf"}
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_IMAGE"


async def test_presign_requires_membership(client: AsyncClient, direct: FakeDirectStorage):
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)

    response = await client.post(
        _presign_url(fid, mid), json={"content_type": "image/jpeg"}, headers=XIAOLIN
    )
    # 404, not 403: non-members must not learn that the family exists.
    assert response.status_code == 404


async def test_presign_501_without_direct_support(
    client: AsyncClient, proxy_only: FakeProxyOnlyStorage
):
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)

    response = await client.post(_presign_url(fid, mid), json={"content_type": "image/jpeg"})
    assert response.status_code == 501
    assert response.json()["error"]["code"] == "STORAGE_NO_DIRECT_URL"


# ---- Commit ---------------------------------------------------------------


async def test_commit_turns_object_into_media(client: AsyncClient, direct: FakeDirectStorage):
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)
    media_id = str(uuid.uuid4())

    ticket = await _ticket(client, fid, mid, content_type="image/png", client_id=media_id)
    direct.objects[ticket["key"]] = _png()

    commit = await client.post(
        _commit_url(fid, mid),
        json={
            "media_id": media_id,
            "key": ticket["key"],
            "content_type": "image/png",
            "width": 120,
            "height": 90,
        },
    )
    assert commit.status_code == 201, commit.text
    row = commit.json()["data"]
    assert row["id"] == media_id
    assert row["kind"] == "photo"
    assert row["content_type"] == "image/png"
    assert row["size_bytes"] == len(direct.objects[ticket["key"]])
    assert row["width"] == 120 and row["height"] == 90

    # Visible through the normal read path too.
    detail = await client.get(f"{MEM_BASE.format(fid=fid)}/{mid}")
    assert len(detail.json()["data"]["media"]) == 1


async def test_commit_is_idempotent(client: AsyncClient, direct: FakeDirectStorage):
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)
    media_id = str(uuid.uuid4())

    ticket = await _ticket(client, fid, mid, content_type="image/png", client_id=media_id)
    direct.objects[ticket["key"]] = _png()
    body = {"media_id": media_id, "key": ticket["key"], "content_type": "image/png"}

    first = await client.post(_commit_url(fid, mid), json=body)
    second = await client.post(_commit_url(fid, mid), json=body)
    assert first.status_code == 201 and second.status_code == 201
    assert first.json()["data"]["id"] == second.json()["data"]["id"]

    detail = await client.get(f"{MEM_BASE.format(fid=fid)}/{mid}")
    assert len(detail.json()["data"]["media"]) == 1


async def test_commit_rejects_foreign_key(client: AsyncClient, direct: FakeDirectStorage):
    """A ticket is only valid for the key it was minted for."""
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)
    other_mid = await _create_memory(client, fid)
    media_id = str(uuid.uuid4())

    ticket = await _ticket(client, fid, mid, content_type="image/png", client_id=media_id)
    direct.objects[ticket["key"]] = _png()

    # Same media_id, but the key says it belongs to a different memory.
    forged = ticket["key"].replace(f"/{mid}/", f"/{other_mid}/")
    response = await client.post(
        _commit_url(fid, mid),
        json={"media_id": media_id, "key": forged, "content_type": "image/png"},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_commit_rejects_missing_object(client: AsyncClient, direct: FakeDirectStorage):
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)
    media_id = str(uuid.uuid4())

    ticket = await _ticket(client, fid, mid, content_type="image/png", client_id=media_id)
    # Nothing uploaded — the client called commit too early.

    response = await client.post(
        _commit_url(fid, mid),
        json={"media_id": media_id, "key": ticket["key"], "content_type": "image/png"},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "DIRECT_UPLOAD_MISSING"


async def test_commit_enforces_size_cap(client: AsyncClient, direct: FakeDirectStorage):
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)
    media_id = str(uuid.uuid4())

    ticket = await _ticket(client, fid, mid, content_type="image/png", client_id=media_id)
    direct.objects[ticket["key"]] = _png()
    direct.forced_size = PHOTO_MB * 1024 * 1024 + 1

    response = await client.post(
        _commit_url(fid, mid),
        json={"media_id": media_id, "key": ticket["key"], "content_type": "image/png"},
    )
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "FILE_TOO_LARGE"


async def test_commit_rejects_declared_kind_mismatch(
    client: AsyncClient, direct: FakeDirectStorage
):
    """Bytes say video, client said photo — catch it instead of storing it."""
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)
    media_id = str(uuid.uuid4())

    ticket = await _ticket(client, fid, mid, content_type="image/jpeg", client_id=media_id)
    direct.objects[ticket["key"]] = _mp4_head()

    response = await client.post(
        _commit_url(fid, mid),
        json={"media_id": media_id, "key": ticket["key"], "content_type": "image/jpeg"},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_IMAGE"


async def test_commit_accepts_video_with_duration(
    client: AsyncClient, direct: FakeDirectStorage
):
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)
    media_id = str(uuid.uuid4())

    ticket = await _ticket(client, fid, mid, content_type="video/mp4", client_id=media_id)
    direct.objects[ticket["key"]] = _mp4_head()

    response = await client.post(
        _commit_url(fid, mid),
        json={
            "media_id": media_id,
            "key": ticket["key"],
            "content_type": "video/mp4",
            "duration_ms": 8400,
            "width": 1920,  # ignored for video
            "height": 1080,
        },
    )
    assert response.status_code == 201, response.text
    row = response.json()["data"]
    assert row["kind"] == "video"
    assert row["duration_ms"] == 8400
    assert row["width"] is None and row["height"] is None


async def test_commit_requires_membership(client: AsyncClient, direct: FakeDirectStorage):
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)
    media_id = str(uuid.uuid4())

    ticket = await _ticket(client, fid, mid, content_type="image/png", client_id=media_id)
    direct.objects[ticket["key"]] = _png()

    response = await client.post(
        _commit_url(fid, mid),
        json={"media_id": media_id, "key": ticket["key"], "content_type": "image/png"},
        headers=XIAOLIN,
    )
    assert response.status_code == 404


async def test_commit_501_without_direct_support(
    client: AsyncClient, proxy_only: FakeProxyOnlyStorage
):
    fid = await _create_family(client)
    mid = await _create_memory(client, fid)

    response = await client.post(
        _commit_url(fid, mid),
        json={
            "media_id": str(uuid.uuid4()),
            "key": f"memory/{fid}/{mid}/{uuid.uuid4()}.png",
            "content_type": "image/png",
        },
    )
    assert response.status_code == 501
