"""Memory plugin tests — timeline CRUD, media upload, comments, visibility,
and the latest-title home preview."""

import uuid
from io import BytesIO

import pytest
from httpx import AsyncClient
from PIL import Image

# Seed users (see app/core/seed.py): 老陈 owns by default, 小林 joins.
LAOCHEN = "019000a0-1100-7000-8000-000000000001"
XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}

MEM_BASE = "/api/v1/families/{fid}/plugins/memory/memories"


@pytest.fixture
def png_bytes() -> bytes:
    img = Image.new("RGB", (120, 90), color=(40, 120, 200))
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _unique_name() -> str:
    return f"回忆测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


async def _family_with_xiaolin(client: AsyncClient) -> str:
    fid = await _create_family(client)
    invite = await client.post(
        f"/api/v1/families/{fid}/invitations",
        json={"role": "member", "ttl_seconds": 3600, "channel": "link"},
    )
    code = invite.json()["data"]["code"]
    await client.post(f"/api/v1/invitations/{code}/accept", headers=XIAOLIN)
    return fid


async def test_create_and_list_memory(client: AsyncClient) -> None:
    fid = await _create_family(client)
    create = await client.post(
        MEM_BASE.format(fid=fid),
        json={
            "title": "搬家纪念",
            "body": "新家第一晚。",
            "mood": "🥹",
            "location": "新家",
            "event_date": "2026-05-25",
        },
    )
    assert create.status_code == 201, create.text
    created = create.json()["data"]
    assert created["title"] == "搬家纪念"
    assert created["event_date"] == "2026-05-25"
    assert created["author_name"]  # injected from membership
    assert created["media"] == []
    assert created["comment_count"] == 0

    listed = await client.get(MEM_BASE.format(fid=fid))
    assert listed.status_code == 200
    data = listed.json()["data"]
    assert len(data) == 1
    assert data[0]["title"] == "搬家纪念"


async def test_empty_title_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    resp = await client.post(MEM_BASE.format(fid=fid), json={"title": "   "})
    assert resp.status_code == 400


async def test_upload_photo_attaches_media(client: AsyncClient, png_bytes: bytes) -> None:
    fid = await _create_family(client)
    mid = (
        await client.post(MEM_BASE.format(fid=fid), json={"title": "第一张"})
    ).json()["data"]["id"]

    up = await client.post(
        f"{MEM_BASE.format(fid=fid)}/{mid}/media",
        files={"file": ("a.png", png_bytes, "image/png")},
    )
    assert up.status_code == 201, up.text
    media = up.json()["data"]
    assert media["kind"] == "photo"
    assert media["size_bytes"] == len(png_bytes)
    assert media["width"] == 120 and media["height"] == 90
    assert "/raw" in media["url"]

    # The raw endpoint returns the exact bytes (url already carries /api/v1).
    raw = await client.get(media["url"])
    assert raw.status_code == 200
    assert raw.content == png_bytes

    detail = await client.get(f"{MEM_BASE.format(fid=fid)}/{mid}")
    assert len(detail.json()["data"]["media"]) == 1


async def test_raw_redirects_to_presigned_url_when_storage_is_cos(
    client: AsyncClient, png_bytes: bytes, monkeypatch
) -> None:
    """When the storage backend is COS (presignable), `/raw` should 302 the
    client to a temporary signed URL instead of streaming bytes."""

    class _FakeCos:
        # Records the call so we can assert the right key + ttl, and verifies
        # the fallback `storage.get` is not invoked.
        def __init__(self) -> None:
            self.signed: list[tuple[str, int]] = []

        async def put(self, key: str, data: bytes, content_type: str) -> None:
            # Upload still flows through the storage layer; the test doesn't
            # care where bytes physically land, only that put is honoured.
            self._stored = (key, data, content_type)

        async def get(self, key: str) -> bytes:
            raise AssertionError("get() should never run when redirect path applies")

        async def delete(self, key: str) -> None: ...
        async def exists(self, key: str) -> bool:
            return True

        async def presigned_get_url(self, key: str, *, ttl_seconds: int) -> str:
            self.signed.append((key, ttl_seconds))
            return f"https://fake.cos.example/{key}?sig=abc&exp={ttl_seconds}"

    fake = _FakeCos()
    # Patch the symbol the routes module actually reads (it imports `storage`
    # into its own namespace at module load time).
    from app.plugins.memory import routes as memory_routes

    monkeypatch.setattr(memory_routes, "storage", fake)

    fid = await _create_family(client)
    mid = (
        await client.post(MEM_BASE.format(fid=fid), json={"title": "去 COS"})
    ).json()["data"]["id"]

    up = await client.post(
        f"{MEM_BASE.format(fid=fid)}/{mid}/media",
        files={"file": ("a.png", png_bytes, "image/png")},
    )
    assert up.status_code == 201, up.text
    media_url = up.json()["data"]["url"]

    # /raw should 302 to the fake signed URL, NOT stream bytes back.
    raw = await client.get(media_url, follow_redirects=False)
    assert raw.status_code == 302
    assert raw.headers["location"].startswith("https://fake.cos.example/")
    assert "sig=" in raw.headers["location"]

    # And the route asked for a 1-hour TTL on the signed URL.
    assert len(fake.signed) == 1
    key, ttl = fake.signed[0]
    assert key.startswith(f"memory/{fid}/{mid}/")
    assert ttl == 3600


async def test_garbage_upload_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    mid = (
        await client.post(MEM_BASE.format(fid=fid), json={"title": "x"})
    ).json()["data"]["id"]
    resp = await client.post(
        f"{MEM_BASE.format(fid=fid)}/{mid}/media",
        files={"file": ("a.bin", b"not an image or video", "image/png")},
    )
    assert resp.status_code == 400


async def test_comment_flow(client: AsyncClient) -> None:
    fid = await _family_with_xiaolin(client)
    mid = (
        await client.post(MEM_BASE.format(fid=fid), json={"title": "散步"})
    ).json()["data"]["id"]

    add = await client.post(
        f"{MEM_BASE.format(fid=fid)}/{mid}/comments",
        json={"body": "明天再去一次吧"},
        headers=XIAOLIN,
    )
    assert add.status_code == 201, add.text
    comment = add.json()["data"]
    assert comment["body"] == "明天再去一次吧"
    assert comment["author_name"]

    detail = await client.get(f"{MEM_BASE.format(fid=fid)}/{mid}")
    body = detail.json()["data"]
    assert body["comment_count"] == 1
    assert len(body["comments"]) == 1

    cid = comment["id"]
    # 老陈 (not the author) can't delete 小林's comment.
    forbidden = await client.delete(f"{MEM_BASE.format(fid=fid)}/{mid}/comments/{cid}")
    assert forbidden.status_code == 403
    # The author can.
    deleted = await client.delete(
        f"{MEM_BASE.format(fid=fid)}/{mid}/comments/{cid}", headers=XIAOLIN
    )
    assert deleted.status_code == 200


async def test_private_memory_hidden_from_partner(client: AsyncClient) -> None:
    fid = await _family_with_xiaolin(client)
    mid = (
        await client.post(
            MEM_BASE.format(fid=fid),
            json={"title": "悄悄话", "visibility": "private"},
        )
    ).json()["data"]["id"]

    # 小林 doesn't see it in the list and can't open it.
    listed = await client.get(MEM_BASE.format(fid=fid), headers=XIAOLIN)
    assert all(m["id"] != mid for m in listed.json()["data"])
    opened = await client.get(f"{MEM_BASE.format(fid=fid)}/{mid}", headers=XIAOLIN)
    assert opened.status_code == 404

    # The author still sees it.
    mine = await client.get(MEM_BASE.format(fid=fid))
    assert any(m["id"] == mid for m in mine.json()["data"])


async def test_invalid_visibility_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    resp = await client.post(
        MEM_BASE.format(fid=fid),
        json={"title": "x", "visibility": "world"},
    )
    assert resp.status_code == 400


async def test_preview_shows_latest_title_and_count(client: AsyncClient) -> None:
    from app.core.database import async_session_maker
    from app.models.plugin import InstalledPlugin
    from app.plugins.memory.service import preview_hook

    fid = await _create_family(client)
    await client.post(
        MEM_BASE.format(fid=fid),
        json={"title": "旧的", "event_date": "2026-05-01"},
    )
    await client.post(
        MEM_BASE.format(fid=fid),
        json={"title": "最新的", "mood": "😍", "event_date": "2026-05-20"},
    )

    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="memory")
    async with async_session_maker() as session:
        preview = await preview_hook(session, ip, uuid.UUID(LAOCHEN))
    assert preview.primary == "最新的"
    assert preview.secondary == "共 2 条回忆"
    assert preview.color_token == "memory"
    assert preview.emoji == "😍"
    # No photos yet → carousel URLs are None (home card falls back to plain layout).
    assert preview.image_urls is None


async def test_preview_image_urls_for_carousel(
    client: AsyncClient, png_bytes: bytes
) -> None:
    """Memory's home preview surfaces the latest photos for the 4×2 carousel.

    Order is newest-first (by media created_at), capped at 5. Photos from
    `private` memories of OTHER users must not leak through.
    """
    from app.core.database import async_session_maker
    from app.models.plugin import InstalledPlugin
    from app.plugins.memory.service import preview_hook

    fid = await _family_with_xiaolin(client)

    # Three memories: 小林 makes a private one (老陈 must NOT see its photo);
    # 老陈 makes a public one with two photos.
    priv = (
        await client.post(
            MEM_BASE.format(fid=fid),
            json={"title": "私密", "visibility": "private"},
            headers=XIAOLIN,
        )
    ).json()["data"]
    await client.post(
        f"{MEM_BASE.format(fid=fid)}/{priv['id']}/media",
        files={"file": ("p.png", png_bytes, "image/png")},
        headers=XIAOLIN,
    )

    pub = (
        await client.post(MEM_BASE.format(fid=fid), json={"title": "公开"})
    ).json()["data"]
    for name in ("a.png", "b.png"):
        await client.post(
            f"{MEM_BASE.format(fid=fid)}/{pub['id']}/media",
            files={"file": (name, png_bytes, "image/png")},
        )

    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="memory")
    async with async_session_maker() as session:
        preview = await preview_hook(session, ip, uuid.UUID(LAOCHEN))

    # 老陈 (non-author of the private memory) sees only the 2 public photos.
    assert preview.image_urls is not None
    assert len(preview.image_urls) == 2
    for url in preview.image_urls:
        assert url.startswith(f"/api/v1/families/{fid}/plugins/memory/memories/")
        assert url.endswith("/raw")


async def test_author_avatar_url_surfaced_and_servable(
    client: AsyncClient, png_bytes: bytes
) -> None:
    """When the author uploaded a real avatar, the memory carries a member-avatar
    URL that any co-member can fetch; otherwise it's null (client uses emoji)."""
    fid = await _family_with_xiaolin(client)

    # 小林 records a memory without an avatar → author_avatar_url is null.
    no_av = (
        await client.post(
            MEM_BASE.format(fid=fid), json={"title": "无头像"}, headers=XIAOLIN
        )
    ).json()["data"]
    assert no_av["author_avatar_url"] is None

    # 老陈 uploads an avatar, then records a memory.
    await client.post(
        "/api/v1/me/avatar",
        files={"file": ("a.png", png_bytes, "image/png")},
    )
    mem = (
        await client.post(MEM_BASE.format(fid=fid), json={"title": "有头像"})
    ).json()["data"]
    url = mem["author_avatar_url"]
    assert url is not None
    assert f"/families/{fid}/members/" in url and "/avatar" in url

    # 小林 (co-member) can fetch 老陈's avatar bytes through that URL.
    raw = await client.get(url, headers=XIAOLIN)
    assert raw.status_code == 200
    assert raw.content == png_bytes


async def test_member_avatar_blocked_for_non_member(
    client: AsyncClient, png_bytes: bytes
) -> None:
    fid = await _create_family(client)  # 老陈 only
    await client.post(
        "/api/v1/me/avatar",
        files={"file": ("a.png", png_bytes, "image/png")},
    )
    laochen_id = LAOCHEN
    # 小宝 is not in this family → must not be able to read the avatar.
    resp = await client.get(
        f"/api/v1/families/{fid}/members/{laochen_id}/avatar",
        headers={"X-User-Id": "019000a0-1100-7000-8000-000000000003"},
    )
    assert resp.status_code == 404


async def test_preview_empty_state(client: AsyncClient) -> None:
    from app.core.database import async_session_maker
    from app.models.plugin import InstalledPlugin
    from app.plugins.memory.service import preview_hook

    fid = await _create_family(client)
    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="memory")
    async with async_session_maker() as session:
        preview = await preview_hook(session, ip, uuid.UUID(LAOCHEN))
    assert preview.primary == "还没有回忆"
