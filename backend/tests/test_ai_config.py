"""AI 集成设置 endpoint tests — CRUD, key masking, env seed migration, test guard.

Drives the real ASGI app (needs the test DB). The encryption key is injected on
the shared settings singleton so the app can encrypt at rest.
"""

import uuid

import pytest
from cryptography.fernet import Fernet
from httpx import AsyncClient

from app.core import crypto
from app.core.config import settings

BASE = "/api/v1/families/{fid}/ai-models"


@pytest.fixture
def _crypto_key(monkeypatch):
    """Give the app a Fernet key and a blank static config (no accidental seed)."""
    monkeypatch.setattr(settings, "ai_secret_key", Fernet.generate_key().decode())
    monkeypatch.setattr(settings, "kimi_api_key", "")
    crypto.reset_cache()
    yield
    crypto.reset_cache()


async def _create_family(client: AsyncClient) -> str:
    resp = await client.post(
        "/api/v1/families", json={"name": f"测试-{uuid.uuid4().hex[:6]}"}
    )
    return resp.json()["data"]["id"]


async def test_get_lists_four_types_unconfigured(client: AsyncClient, _crypto_key) -> None:
    fid = await _create_family(client)
    resp = await client.get(BASE.format(fid=fid))
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert [m["ai_type"] for m in data] == ["multimodal", "text", "image", "video"]
    assert all(m["configured"] is False for m in data)
    # multimodal/text are callable; image/video are placeholders.
    by_type = {m["ai_type"]: m for m in data}
    assert by_type["multimodal"]["callable"] is True
    assert by_type["image"]["callable"] is False


async def test_upsert_then_read_masks_key(client: AsyncClient, _crypto_key) -> None:
    fid = await _create_family(client)
    resp = await client.put(
        BASE.format(fid=fid) + "/multimodal",
        json={
            "label": "Kimi",
            "base_url": "https://api.moonshot.cn/v1",
            "model": "kimi-k2.6",
            "api_key": "sk-supersecret-9999",
            "enabled": True,
        },
    )
    assert resp.status_code == 200, resp.text
    m = resp.json()["data"]
    assert m["configured"] is True
    assert m["has_key"] is True
    assert m["key_hint"] == "9999"
    assert m["model"] == "kimi-k2.6"
    # The plaintext key is never echoed back anywhere in the response.
    assert "sk-supersecret-9999" not in resp.text

    got = await client.get(BASE.format(fid=fid))
    multimodal = next(x for x in got.json()["data"] if x["ai_type"] == "multimodal")
    assert multimodal["has_key"] is True
    assert multimodal["label"] == "Kimi"


async def test_edit_without_key_keeps_existing(client: AsyncClient, _crypto_key) -> None:
    fid = await _create_family(client)
    await client.put(
        BASE.format(fid=fid) + "/text",
        json={
            "label": "DeepSeek",
            "base_url": "https://api.deepseek.com/v1",
            "model": "deepseek-chat",
            "api_key": "sk-abcd1234",
        },
    )
    # Edit label only, no api_key → key retained.
    resp = await client.put(
        BASE.format(fid=fid) + "/text",
        json={
            "label": "DeepSeek 改名",
            "base_url": "https://api.deepseek.com/v1",
            "model": "deepseek-chat",
        },
    )
    assert resp.status_code == 200
    m = resp.json()["data"]
    assert m["label"] == "DeepSeek 改名"
    assert m["has_key"] is True
    assert m["key_hint"] == "1234"


async def test_create_without_key_rejected(client: AsyncClient, _crypto_key) -> None:
    fid = await _create_family(client)
    resp = await client.put(
        BASE.format(fid=fid) + "/multimodal",
        json={
            "label": "Kimi",
            "base_url": "https://api.moonshot.cn/v1",
            "model": "kimi-k2.6",
        },
    )
    assert resp.status_code == 400


async def test_delete_removes(client: AsyncClient, _crypto_key) -> None:
    fid = await _create_family(client)
    await client.put(
        BASE.format(fid=fid) + "/multimodal",
        json={
            "label": "Kimi",
            "base_url": "https://api.moonshot.cn/v1",
            "model": "kimi-k2.6",
            "api_key": "sk-zzzz",
        },
    )
    resp = await client.delete(BASE.format(fid=fid) + "/multimodal")
    assert resp.status_code == 200
    got = await client.get(BASE.format(fid=fid))
    multimodal = next(x for x in got.json()["data"] if x["ai_type"] == "multimodal")
    assert multimodal["configured"] is False


async def test_unknown_type_rejected(client: AsyncClient, _crypto_key) -> None:
    fid = await _create_family(client)
    resp = await client.put(
        BASE.format(fid=fid) + "/telepathy",
        json={"label": "x", "base_url": "y", "model": "z", "api_key": "k"},
    )
    assert resp.status_code == 400


async def test_env_kimi_seeds_multimodal(client: AsyncClient, monkeypatch) -> None:
    """A family with the deprecated env Kimi config set gets a multimodal row
    auto-seeded on first read (one-time migration)."""
    monkeypatch.setattr(settings, "ai_secret_key", Fernet.generate_key().decode())
    monkeypatch.setattr(settings, "kimi_api_key", "sk-env-key-5678")
    monkeypatch.setattr(settings, "kimi_base_url", "https://api.moonshot.cn/v1")
    monkeypatch.setattr(settings, "kimi_model", "kimi-k2.6")
    crypto.reset_cache()
    try:
        fid = await _create_family(client)
        resp = await client.get(BASE.format(fid=fid))
        multimodal = next(
            x for x in resp.json()["data"] if x["ai_type"] == "multimodal"
        )
        assert multimodal["configured"] is True
        assert multimodal["has_key"] is True
        assert multimodal["key_hint"] == "5678"
        assert multimodal["model"] == "kimi-k2.6"
    finally:
        crypto.reset_cache()


async def test_test_endpoint_unconfigured_returns_400(client: AsyncClient, _crypto_key) -> None:
    fid = await _create_family(client)
    resp = await client.post(BASE.format(fid=fid) + "/text/test")
    assert resp.status_code == 400


async def test_image_type_not_testable(client: AsyncClient, _crypto_key) -> None:
    fid = await _create_family(client)
    resp = await client.post(BASE.format(fid=fid) + "/image/test")
    assert resp.status_code == 400
