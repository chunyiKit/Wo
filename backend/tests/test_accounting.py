"""Accounting plugin tests — expenses, budget, summary, and preview coloring."""

import uuid
from io import BytesIO

from httpx import AsyncClient
from PIL import Image

XIAOBAO = {"X-User-Id": "019000a0-1100-7000-8000-000000000003"}


def _unique_name() -> str:
    return f"记账测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


async def _add_expense(client: AsyncClient, fid: str, **overrides: object) -> dict:
    payload: dict[str, object] = {"amount": "100.00", "category": "dining"}
    payload.update(overrides)
    response = await client.post(
        f"/api/v1/families/{fid}/plugins/accounting/transactions", json=payload
    )
    assert response.status_code == 201, response.text
    return response.json()["data"]


async def test_create_and_list_expense(client: AsyncClient) -> None:
    fid = await _create_family(client)
    created = await _add_expense(
        client, fid, amount="59.90", category="shopping", note="买菜"
    )
    assert created["category"] == "shopping"
    assert created["note"] == "买菜"
    # Recorder display info is embedded for the timeline.
    assert created["creator_name"] is not None
    assert created["creator_emoji"] is not None
    # `creator_avatar_url` carries the field (positive case covered separately);
    # don't assert its value here since the shared seed user's avatar state can
    # vary across the suite.
    assert "creator_avatar_url" in created

    listing = await client.get(
        f"/api/v1/families/{fid}/plugins/accounting/transactions"
    )
    assert listing.status_code == 200
    assert len(listing.json()["data"]) == 1


async def test_creator_avatar_url_when_recorder_has_avatar(
    client: AsyncClient,
) -> None:
    """A recorder with a real uploaded avatar surfaces a member-avatar URL."""
    img = Image.new("RGB", (40, 40), color=(200, 120, 40))
    buf = BytesIO()
    img.save(buf, format="PNG")
    await client.post(
        "/api/v1/me/avatar",
        files={"file": ("a.png", buf.getvalue(), "image/png")},
    )
    fid = await _create_family(client)
    created = await _add_expense(client, fid, amount="12.00", category="dining")
    url = created["creator_avatar_url"]
    assert url is not None
    assert f"/families/{fid}/members/" in url and "/avatar" in url


async def test_list_is_time_desc(client: AsyncClient) -> None:
    fid = await _create_family(client)
    first = await _add_expense(client, fid, note="先")
    second = await _add_expense(client, fid, note="后")
    rows = (
        await client.get(f"/api/v1/families/{fid}/plugins/accounting/transactions")
    ).json()["data"]
    # Newest first.
    assert rows[0]["id"] == second["id"]
    assert rows[1]["id"] == first["id"]


async def test_unknown_category_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    response = await client.post(
        f"/api/v1/families/{fid}/plugins/accounting/transactions",
        json={"amount": "10.00", "category": "bogus"},
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_update_expense(client: AsyncClient) -> None:
    fid = await _create_family(client)
    created = await _add_expense(client, fid, amount="10.00", category="dining")
    updated = await client.put(
        f"/api/v1/families/{fid}/plugins/accounting/transactions/{created['id']}",
        json={"amount": "88.00", "category": "car", "note": "加油"},
    )
    assert updated.status_code == 200, updated.text
    data = updated.json()["data"]
    assert data["category"] == "car"
    assert data["note"] == "加油"
    assert float(data["amount"]) == 88.0


async def test_delete_expense(client: AsyncClient) -> None:
    fid = await _create_family(client)
    created = await _add_expense(client, fid)
    deleted = await client.delete(
        f"/api/v1/families/{fid}/plugins/accounting/transactions/{created['id']}"
    )
    assert deleted.status_code == 200
    listing = await client.get(
        f"/api/v1/families/{fid}/plugins/accounting/transactions"
    )
    assert listing.json()["data"] == []


async def test_update_nonexistent_returns_404(client: AsyncClient) -> None:
    fid = await _create_family(client)
    response = await client.put(
        f"/api/v1/families/{fid}/plugins/accounting/transactions/{uuid.uuid4()}",
        json={"note": "无所谓"},
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "NOT_FOUND"


async def test_non_member_returns_404(client: AsyncClient) -> None:
    fid = await _create_family(client)
    response = await client.get(
        f"/api/v1/families/{fid}/plugins/accounting/transactions", headers=XIAOBAO
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "FAMILY_NOT_FOUND"


async def test_budget_set_and_summary(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # No budget yet.
    budget = (
        await client.get(f"/api/v1/families/{fid}/plugins/accounting/budget")
    ).json()["data"]
    assert budget["monthly_amount"] is None

    await client.put(
        f"/api/v1/families/{fid}/plugins/accounting/budget",
        json={"monthly_amount": "1000.00"},
    )
    await _add_expense(client, fid, amount="300.00")

    summary = (
        await client.get(f"/api/v1/families/{fid}/plugins/accounting/summary")
    ).json()["data"]
    assert float(summary["month_total"]) == 300.0
    assert float(summary["budget"]) == 1000.0
    assert float(summary["remaining"]) == 700.0


async def test_month_filter_scopes_transactions_and_summary(
    client: AsyncClient,
) -> None:
    from datetime import date

    fid = await _create_family(client)
    await _add_expense(client, fid, amount="120.00")

    today = date.today()
    # A month with no expenses (two months back) should be empty / zero.
    past = date(today.year, today.month, 1)
    prev_month = 12 if past.month <= 2 else past.month - 2
    prev_year = past.year - 1 if past.month <= 2 else past.year

    empty = await client.get(
        f"/api/v1/families/{fid}/plugins/accounting/transactions"
        f"?year={prev_year}&month={prev_month}"
    )
    assert empty.json()["data"] == []

    empty_summary = (
        await client.get(
            f"/api/v1/families/{fid}/plugins/accounting/summary"
            f"?year={prev_year}&month={prev_month}"
        )
    ).json()["data"]
    assert float(empty_summary["month_total"]) == 0.0

    # The current month sees the expense.
    current = await client.get(
        f"/api/v1/families/{fid}/plugins/accounting/transactions"
        f"?year={today.year}&month={today.month}"
    )
    assert len(current.json()["data"]) == 1
    current_summary = (
        await client.get(
            f"/api/v1/families/{fid}/plugins/accounting/summary"
            f"?year={today.year}&month={today.month}"
        )
    ).json()["data"]
    assert float(current_summary["month_total"]) == 120.0


async def test_preview_compact_shows_only_total(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # Install as a 2×1 compact card.
    await client.post(
        f"/api/v1/families/{fid}/plugins",
        json={"plugin_id": "accounting", "layout": {"col": 0, "row": 0, "cw": 2, "ch": 1}},
    )
    await _add_expense(client, fid, amount="123.00")
    preview = (
        await client.get(f"/api/v1/families/{fid}/plugins")
    ).json()["data"][0]["preview"]
    assert "123" in preview["primary"]
    assert preview["secondary"] == "本月支出"
    assert preview["secondary_tone"] is None


async def test_preview_budget_tone_thresholds(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "accounting"})
    await client.put(
        f"/api/v1/families/{fid}/plugins/accounting/budget",
        json={"monthly_amount": "1000.00"},
    )

    async def tone() -> str | None:
        data = (await client.get(f"/api/v1/families/{fid}/plugins")).json()["data"][0]
        return data["preview"]["secondary_tone"]

    # 700 remaining (70%) → normal.
    await _add_expense(client, fid, amount="300.00")
    assert await tone() is None
    # 350 remaining (35%) → warning.
    await _add_expense(client, fid, amount="350.00")
    assert await tone() == "warning"
    # 60 remaining (6%) → danger.
    await _add_expense(client, fid, amount="290.00")
    assert await tone() == "danger"


async def test_preview_no_budget(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await client.post(f"/api/v1/families/{fid}/plugins", json={"plugin_id": "accounting"})
    preview = (
        await client.get(f"/api/v1/families/{fid}/plugins")
    ).json()["data"][0]["preview"]
    assert preview["secondary"] == "未设预算"
