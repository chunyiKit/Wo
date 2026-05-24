"""Anniversary plugin content tests + preview computation."""

import uuid
from datetime import date, timedelta

from httpx import AsyncClient

XIAOBAO = {"X-User-Id": "019000a0-1100-7000-8000-000000000003"}


def _unique_name() -> str:
    return f"纪念日测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


async def test_create_and_list_anniversary(client: AsyncClient) -> None:
    fid = await _create_family(client)
    create = await client.post(
        f"/api/v1/families/{fid}/plugins/anniversary/dates",
        json={
            "name": "结婚纪念日",
            "event_date": "2024-03-15",
            "emoji": "💞",
            "note": "在杭州登记的",
        },
    )
    assert create.status_code == 201, create.text
    created = create.json()["data"]
    assert created["name"] == "结婚纪念日"
    assert created["event_date"] == "2024-03-15"

    listing = await client.get(f"/api/v1/families/{fid}/plugins/anniversary/dates")
    assert listing.status_code == 200
    assert len(listing.json()["data"]) == 1


async def test_delete_anniversary(client: AsyncClient) -> None:
    fid = await _create_family(client)
    created = (
        await client.post(
            f"/api/v1/families/{fid}/plugins/anniversary/dates",
            json={"name": "测试", "event_date": "2024-01-01"},
        )
    ).json()["data"]

    deleted = await client.delete(
        f"/api/v1/families/{fid}/plugins/anniversary/dates/{created['id']}"
    )
    assert deleted.status_code == 200

    listing = await client.get(f"/api/v1/families/{fid}/plugins/anniversary/dates")
    assert listing.json()["data"] == []


async def test_anniversary_non_member_returns_404(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # 小宝 (not a member) tries to read.
    response = await client.get(
        f"/api/v1/families/{fid}/plugins/anniversary/dates",
        headers=XIAOBAO,
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "FAMILY_NOT_FOUND"


async def test_preview_says_empty_when_no_dates(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "anniversary"})

    listing = await client.get(f"/api/v1/families/{fid}/plugins")
    preview = listing.json()["data"][0]["preview"]
    assert "还没有记录" in preview["primary"]


async def test_preview_shows_next_upcoming_date(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "anniversary"})

    # A date 30 days away (always upcoming regardless of when test runs).
    soon = date.today() + timedelta(days=30)
    await client.post(
        f"/api/v1/families/{fid}/plugins/anniversary/dates",
        json={"name": "下次", "event_date": soon.isoformat(), "emoji": "🎉"},
    )
    # A date much further out — should NOT be the closest.
    far = date(date.today().year + 5, 12, 31)
    await client.post(
        f"/api/v1/families/{fid}/plugins/anniversary/dates",
        json={"name": "远期", "event_date": far.isoformat(), "emoji": "🎁"},
    )

    listing = await client.get(f"/api/v1/families/{fid}/plugins")
    preview = listing.json()["data"][0]["preview"]
    assert "下次" in preview["primary"]
    assert "30 天" in preview["secondary"]
