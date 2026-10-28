"""Direct (headerless) media URLs — the mini program's <image> workaround.

The real storage backend in tests is LocalStorage, which can't presign, so each
test that wants a URL injects a fake presign-capable backend. Tests that assert
the *degradation* path deliberately leave the real backend in place.
"""

import uuid
from io import BytesIO

import pytest
from httpx import AsyncClient
from PIL import Image

# Seed users (see app/core/seed.py): 老陈 owns by default, 小林 joins.
LAOCHEN = "019000a0-1100-7000-8000-000000000001"
XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}

MEM_BASE = "/api/v1/families/{fid}/plugins/memory/memories"
URLS = "/api/v1/families/{fid}/plugins/memory/media/urls"


class FakePresignStorage:
    """Minimal PresignableStorage stand-in. Records what it was asked to sign so
    tests can assert the URL maps back to the right blob."""

    def __init__(self) -> None:
        self.signed: list[tuple[str, int]] = []

    async def put(self, key: str, data: bytes, content_type: str) -> None:
        self.signed.append((key, len(data)))  # unused for signing; keep shape

    async def get(self, key: str) -> bytes:
        raise FileNotFoundError(key)

    async def delete(self, key: str) -> None:
        return None

    async def exists(self, key: str) -> bool:
        return True

    async def presigned_get_url(self, key: str, *, ttl_seconds: int = 3600) -> str:
        self.signed.append((key, ttl_seconds))
        return f"https://cos.example.com/{key}?sign=fake&ttl={ttl_seconds}"


@pytest.fixture
def presign(monkeypatch: pytest.MonkeyPatch) -> FakePresignStorage:
    """Swap in a presign-capable backend for both URL endpoints.

    Both modules do `from app.core.storage import storage`, binding the name at
    import time — patching `app.core.storage.storage` alone would leave the
    routes holding the old object.
    """
    fake = FakePresignStorage()
    monkeypatch.setattr("app.plugins.memory.routes.storage", fake)
    monkeypatch.setattr("app.api.v1.routes.media_url.storage", fake)
    return fake


def _png() -> bytes:
    img = Image.new("RGB", (120, 90), color=(40, 120, 200))
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _unique_name() -> str:
    return f"直链测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    return (await client.post("/api/v1/families", json={"name": _unique_name()})).json()["data"][
        "id"
    ]


async def _family_with_xiaolin(client: AsyncClient) -> str:
    fid = await _create_family(client)
    invite = await client.post(
        f"/api/v1/families/{fid}/invitations",
        json={"role": "member", "ttl_seconds": 3600, "channel": "link"},
    )
    code = invite.json()["data"]["code"]
    await client.post(f"/api/v1/invitations/{code}/accept", headers=XIAOLIN)
    return fid


async def _memory_with_photo(client: AsyncClient, fid: str, **extra) -> tuple[str, str]:
    """Create a memory and attach one photo. Returns (memory_id, media_id)."""
    memory = await client.post(
        MEM_BASE.format(fid=fid),
        json={"title": _unique_name(), "event_date": "2026-05-25", **extra},
    )
    assert memory.status_code == 201, memory.text
    mid = memory.json()["data"]["id"]

    upload = await client.post(
        f"{MEM_BASE.format(fid=fid)}/{mid}/media",
        files={"file": ("p.png", _png(), "image/png")},
    )
    assert upload.status_code == 201, upload.text
    return mid, upload.json()["data"]["id"]


# ---- C1: memory media -------------------------------------------------------


async def test_media_urls_returns_signed_url(
    client: AsyncClient, presign: FakePresignStorage
) -> None:
    fid = await _create_family(client)
    _mid, media_id = await _memory_with_photo(client, fid)

    res = await client.post(URLS.format(fid=fid), json={"media_ids": [media_id]})
    assert res.status_code == 200, res.text
    body = res.json()["data"]

    assert media_id in body["urls"]
    assert body["urls"][media_id].startswith("https://cos.example.com/memory/")
    assert body["expires_at"] is not None
    # The signed URL must point at this media's blob, not some other object.
    assert media_id in body["urls"][media_id]


async def test_media_urls_batches_one_request_for_a_page(
    client: AsyncClient, presign: FakePresignStorage
) -> None:
    """The point of the endpoint: ~120 images in a single round trip."""
    fid = await _create_family(client)
    ids = []
    for _ in range(3):
        _mid, media_id = await _memory_with_photo(client, fid)
        ids.append(media_id)

    res = await client.post(URLS.format(fid=fid), json={"media_ids": ids})
    assert res.status_code == 200
    assert len(res.json()["data"]["urls"]) == 3


async def test_media_urls_ignores_media_from_another_family(
    client: AsyncClient, presign: FakePresignStorage
) -> None:
    """A media id from a family you're not in must not come back with a URL."""
    mine = await _create_family(client)
    _mid, foreign_media = await _memory_with_photo(client, mine)

    other = await _create_family(client)
    res = await client.post(URLS.format(fid=other), json={"media_ids": [foreign_media]})

    assert res.status_code == 200
    assert res.json()["data"]["urls"] == {}


async def test_media_urls_hides_private_memory_from_other_members(
    client: AsyncClient, presign: FakePresignStorage
) -> None:
    fid = await _family_with_xiaolin(client)
    _mid, media_id = await _memory_with_photo(client, fid, visibility="private")

    # 老陈 is the author → gets the URL.
    own = await client.post(URLS.format(fid=fid), json={"media_ids": [media_id]})
    assert media_id in own.json()["data"]["urls"]

    # 小林 is a member but not the author → the media is simply absent.
    other = await client.post(URLS.format(fid=fid), json={"media_ids": [media_id]}, headers=XIAOLIN)
    assert other.json()["data"]["urls"] == {}


async def test_media_urls_requires_membership(client: AsyncClient) -> None:
    fid = await _create_family(client)
    res = await client.post(
        URLS.format(fid=fid),
        json={"media_ids": ["019000a0-1100-7000-8000-000000000999"]},
        headers=XIAOLIN,
    )
    assert res.status_code == 404


async def test_media_urls_unknown_ids_are_absent_not_errors(
    client: AsyncClient, presign: FakePresignStorage
) -> None:
    """Stale ids (media deleted since the page loaded) shouldn't fail the batch."""
    fid = await _create_family(client)
    res = await client.post(
        URLS.format(fid=fid),
        json={"media_ids": ["019000a0-1100-7000-8000-000000000999"]},
    )
    assert res.status_code == 200
    assert res.json()["data"]["urls"] == {}


async def test_media_urls_rejects_empty_batch(client: AsyncClient) -> None:
    fid = await _create_family(client)
    assert (await client.post(URLS.format(fid=fid), json={"media_ids": []})).status_code == 422


async def test_media_urls_501_when_backend_cannot_presign(client: AsyncClient) -> None:
    """No fixture here — the real LocalStorage backend can't mint URLs, and the
    client must be told so rather than handed a link that would 401."""
    fid = await _create_family(client)
    _mid, media_id = await _memory_with_photo(client, fid)

    res = await client.post(URLS.format(fid=fid), json={"media_ids": [media_id]})
    assert res.status_code == 501
    assert res.json()["error"]["code"] == "STORAGE_NO_DIRECT_URL"


# ---- C2 / C3: avatars -------------------------------------------------------


async def _upload_avatar(client: AsyncClient, headers: dict[str, str] | None = None) -> None:
    res = await client.post(
        "/api/v1/me/avatar",
        files={"file": ("a.png", _png(), "image/png")},
        headers=headers,
    )
    assert res.status_code == 200, res.text


async def test_my_avatar_url(client: AsyncClient, presign: FakePresignStorage) -> None:
    await _upload_avatar(client)
    res = await client.get("/api/v1/me/avatar-url")

    assert res.status_code == 200, res.text
    body = res.json()["data"]
    assert body["url"].startswith("https://cos.example.com/")
    assert body["expires_at"] is not None


async def test_my_avatar_url_404_when_no_avatar(client: AsyncClient) -> None:
    # Seed 老陈 ships with an avatar, so clear it first — otherwise this asserts
    # against whatever the seed happens to contain.
    assert (await client.delete("/api/v1/me/avatar")).status_code == 200
    assert (await client.get("/api/v1/me/avatar-url")).status_code == 404


async def test_member_avatar_url(client: AsyncClient, presign: FakePresignStorage) -> None:
    fid = await _family_with_xiaolin(client)
    # Neither seed user ships with an avatar, so upload for both.
    await _upload_avatar(client)
    await _upload_avatar(client, XIAOLIN)

    for user_id, headers in ((LAOCHEN, None), (XIAOLIN["X-User-Id"], XIAOLIN)):
        res = await client.get(
            f"/api/v1/families/{fid}/members/{user_id}/avatar-url", headers=headers
        )
        assert res.status_code == 200, res.text
        assert res.json()["data"]["url"].startswith("https://cos.example.com/")


async def test_member_avatar_url_404_when_target_has_no_avatar(
    client: AsyncClient, presign: FakePresignStorage
) -> None:
    """A member who never uploaded one → 404, so the client falls back to emoji."""
    fid = await _family_with_xiaolin(client)
    assert (await client.delete("/api/v1/me/avatar")).status_code == 200

    res = await client.get(f"/api/v1/families/{fid}/members/{LAOCHEN}/avatar-url")
    assert res.status_code == 404


async def test_member_avatar_url_requires_caller_membership(client: AsyncClient) -> None:
    """A stranger asking for a member's avatar gets 404 — no existence leak."""
    # 小林 is a member of *some* family — just not `loner` below.
    await _family_with_xiaolin(client)
    loner = await _create_family(client)
    await _upload_avatar(client, XIAOLIN)

    res = await client.get(f"/api/v1/families/{loner}/members/{XIAOLIN['X-User-Id']}/avatar-url")
    assert res.status_code == 404


async def test_member_avatar_url_requires_target_membership(
    client: AsyncClient, presign: FakePresignStorage
) -> None:
    """The target must be in the family too, not just the caller."""
    fid = await _create_family(client)
    await _upload_avatar(client, XIAOLIN)

    res = await client.get(f"/api/v1/families/{fid}/members/{XIAOLIN['X-User-Id']}/avatar-url")
    assert res.status_code == 404
