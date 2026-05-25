"""Device registration endpoints — register (upsert) + unregister."""

import uuid

from httpx import AsyncClient

XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}


def _reg_id() -> str:
    return f"reg-{uuid.uuid4().hex[:16]}"


async def test_register_device_returns_token(client: AsyncClient) -> None:
    rid = _reg_id()
    resp = await client.post(
        "/api/v1/devices/register",
        json={"registration_id": rid, "platform": "android"},
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["registration_id"] == rid
    assert data["platform"] == "android"


async def test_register_is_idempotent_upsert(client: AsyncClient) -> None:
    rid = _reg_id()
    first = await client.post(
        "/api/v1/devices/register", json={"registration_id": rid, "platform": "android"}
    )
    # Same registration id, different owner/platform — should reassign, not 409.
    second = await client.post(
        "/api/v1/devices/register",
        json={"registration_id": rid, "platform": "ios"},
        headers=XIAOLIN,
    )
    assert first.status_code == 200
    assert second.status_code == 200, second.text
    assert second.json()["data"]["platform"] == "ios"
    assert second.json()["data"]["id"] == first.json()["data"]["id"]


async def test_register_rejects_bad_platform(client: AsyncClient) -> None:
    resp = await client.post(
        "/api/v1/devices/register",
        json={"registration_id": _reg_id(), "platform": "windows"},
    )
    assert resp.status_code == 422


async def test_unregister_is_idempotent(client: AsyncClient) -> None:
    rid = _reg_id()
    await client.post(
        "/api/v1/devices/register", json={"registration_id": rid, "platform": "android"}
    )
    first = await client.delete(f"/api/v1/devices/{rid}")
    second = await client.delete(f"/api/v1/devices/{rid}")  # already gone
    assert first.status_code == 200
    assert second.status_code == 200
