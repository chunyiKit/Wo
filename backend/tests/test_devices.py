"""Device registration endpoints — register (upsert) + unregister."""

import uuid

from httpx import AsyncClient


def _auth(account):
    return {"Authorization": "Bearer " + account[1]}


def _reg_id() -> str:
    return f"reg-{uuid.uuid4().hex[:16]}"


async def test_register_device_returns_token(client: AsyncClient, authenticated_account) -> None:
    rid = _reg_id()
    resp = await client.post(
        "/api/v1/devices/register",
        json={"registration_id": rid, "platform": "android"},
        headers=_auth(authenticated_account),
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()["data"]
    assert data["registration_id"] == rid
    assert data["platform"] == "android"


async def test_register_is_idempotent_upsert(
    client: AsyncClient, authenticated_account, authenticated_account_factory
) -> None:
    rid = _reg_id()
    first = await client.post(
        "/api/v1/devices/register",
        json={"registration_id": rid, "platform": "android"},
        headers=_auth(authenticated_account),
    )
    # Same registration id, different owner/platform — should reassign, not 409.
    second = await client.post(
        "/api/v1/devices/register",
        json={"registration_id": rid, "platform": "ios"},
        headers=_auth(await authenticated_account_factory()),
    )
    assert first.status_code == 200
    assert second.status_code == 200, second.text
    assert second.json()["data"]["platform"] == "ios"
    assert second.json()["data"]["id"] == first.json()["data"]["id"]


async def test_register_rejects_bad_platform(client: AsyncClient, authenticated_account) -> None:
    resp = await client.post(
        "/api/v1/devices/register",
        json={"registration_id": _reg_id(), "platform": "windows"},
        headers=_auth(authenticated_account),
    )
    assert resp.status_code == 422


async def test_unregister_is_idempotent(client: AsyncClient, authenticated_account) -> None:
    rid = _reg_id()
    await client.post(
        "/api/v1/devices/register",
        json={"registration_id": rid, "platform": "android"},
        headers=_auth(authenticated_account),
    )
    first = await client.delete(f"/api/v1/devices/{rid}", headers=_auth(authenticated_account))
    second = await client.delete(
        f"/api/v1/devices/{rid}", headers=_auth(authenticated_account)
    )  # already gone
    assert first.status_code == 200
    assert second.status_code == 200
