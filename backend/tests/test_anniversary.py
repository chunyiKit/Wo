"""Anniversary plugin content tests + preview computation."""

import uuid
from datetime import date, timedelta

from httpx import AsyncClient

from app.plugins.anniversary.service import days_until

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


async def _create_date(client: AsyncClient, fid: str, **overrides: object) -> dict:
    """Create one anniversary and return the created record."""
    payload: dict[str, object] = {"name": "原始", "event_date": "2024-01-01"}
    payload.update(overrides)
    response = await client.post(
        f"/api/v1/families/{fid}/plugins/anniversary/dates",
        json=payload,
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]


async def test_update_anniversary_all_fields(client: AsyncClient) -> None:
    fid = await _create_family(client)
    created = await _create_date(client, fid, emoji="💞", note="旧备注")

    updated = await client.put(
        f"/api/v1/families/{fid}/plugins/anniversary/dates/{created['id']}",
        json={
            "name": "结婚纪念日",
            "event_date": "2025-06-18",
            "emoji": "💍",
            "is_lunar": True,
            "note": "改到新日期",
        },
    )
    assert updated.status_code == 200, updated.text
    data = updated.json()["data"]
    assert data["id"] == created["id"]
    assert data["name"] == "结婚纪念日"
    assert data["event_date"] == "2025-06-18"
    assert data["emoji"] == "💍"
    assert data["is_lunar"] is True
    assert data["note"] == "改到新日期"

    # 持久化：再 GET 一次确认确实写库了。
    listing = await client.get(f"/api/v1/families/{fid}/plugins/anniversary/dates")
    rows = listing.json()["data"]
    assert len(rows) == 1
    assert rows[0]["name"] == "结婚纪念日"
    assert rows[0]["event_date"] == "2025-06-18"


async def test_update_anniversary_partial_keeps_other_fields(
    client: AsyncClient,
) -> None:
    fid = await _create_family(client)
    created = await _create_date(
        client, fid, name="相识日", event_date="2020-05-20", emoji="🌹", note="保留我"
    )

    # 只改名字，其余字段应保持不变（exclude_unset 语义）。
    updated = await client.put(
        f"/api/v1/families/{fid}/plugins/anniversary/dates/{created['id']}",
        json={"name": "相识纪念日"},
    )
    assert updated.status_code == 200, updated.text
    data = updated.json()["data"]
    assert data["name"] == "相识纪念日"
    assert data["event_date"] == "2020-05-20"
    assert data["emoji"] == "🌹"
    assert data["note"] == "保留我"


async def test_update_nonexistent_returns_404(client: AsyncClient) -> None:
    fid = await _create_family(client)
    missing = uuid.uuid4()
    response = await client.put(
        f"/api/v1/families/{fid}/plugins/anniversary/dates/{missing}",
        json={"name": "无所谓"},
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"


# ── 倒计时推算（纯函数，确定性，不依赖运行当天）─────────────────────────


def test_days_until_solar() -> None:
    today = date(2026, 1, 1)
    target = date(2024, 3, 15)  # 每年公历 3-15 复现
    assert days_until(target, today, is_lunar=False) == (date(2026, 3, 15) - today).days


def test_days_until_lunar() -> None:
    today = date(2026, 1, 1)
    target = date(2024, 3, 15)  # 农历二月初六；2026 年对应公历 3-24
    assert days_until(target, today, is_lunar=True) == (date(2026, 3, 24) - today).days


def test_days_until_today_is_zero() -> None:
    today = date(2026, 5, 24)
    assert days_until(today, today, is_lunar=False) == 0


def test_days_until_lunar_leap_month_edge_does_not_crash() -> None:
    # 2023 含农历闰二月；未来年份未必有闰月，应回退而非报错。
    today = date(2026, 1, 1)
    result = days_until(date(2023, 4, 1), today, is_lunar=True)
    assert 0 <= result <= 400


async def test_list_includes_days_until(client: AsyncClient) -> None:
    fid = await _create_family(client)
    soon = date.today() + timedelta(days=10)
    await client.post(
        f"/api/v1/families/{fid}/plugins/anniversary/dates",
        json={"name": "十天后", "event_date": soon.isoformat()},
    )
    listing = await client.get(f"/api/v1/families/{fid}/plugins/anniversary/dates")
    row = listing.json()["data"][0]
    assert "days_until" in row
    assert row["days_until"] == 10


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
