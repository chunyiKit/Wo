"""Retirement (退休倒计时) tests — accounts/debts/plan CRUD + the dashboard math
(requirements 6 & 7) across the goal_basis / surplus_basis toggles."""

import uuid
from datetime import date
from decimal import Decimal

from httpx import AsyncClient

BASE = "/api/v1/families/{fid}/plugins/retirement"


async def _create_family(client: AsyncClient) -> str:
    resp = await client.post("/api/v1/families", json={"name": f"测试-{uuid.uuid4().hex[:6]}"})
    return resp.json()["data"]["id"]


async def _add_account(client: AsyncClient, fid: str, **over) -> dict:
    body = {
        "name": "工资卡",
        "kind": "deposit",
        "emoji": "🏦",
        "balance": "100000",
        "monthly_income": "0",
        "income_day": 10,
    }
    body.update(over)
    resp = await client.post(BASE.format(fid=fid) + "/accounts", json=body)
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]


async def _add_debt(client: AsyncClient, fid: str, **over) -> dict:
    body = {
        "name": "房贷",
        "kind": "mortgage",
        "balance": "300000",
        "monthly_payment": "8000",
        "payment_day": 5,
    }
    body.update(over)
    resp = await client.post(BASE.format(fid=fid) + "/debts", json=body)
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]


async def _set_plan(client: AsyncClient, fid: str, **body) -> dict:
    resp = await client.put(BASE.format(fid=fid) + "/plan", json=body)
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


async def _dashboard(client: AsyncClient, fid: str) -> dict:
    resp = await client.get(BASE.format(fid=fid) + "/dashboard")
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def _dec(v) -> Decimal:
    return Decimal(str(v))


def _months_ahead(n: int) -> str:
    """An ISO date exactly `n` calendar months ahead of today (mid-month, so the
    day never affects the month diff the dashboard computes)."""
    today = date.today()
    m = today.month - 1 + n
    return date(today.year + m // 12, m % 12 + 1, 15).isoformat()


# ---- CRUD ------------------------------------------------------------------


async def test_account_crud(client: AsyncClient) -> None:
    fid = await _create_family(client)
    acc = await _add_account(client, fid, name="活期", balance="5000")
    assert acc["name"] == "活期"
    assert _dec(acc["balance"]) == Decimal("5000")

    listed = (await client.get(BASE.format(fid=fid) + "/accounts")).json()["data"]
    assert len(listed) == 1

    resp = await client.put(
        BASE.format(fid=fid) + f"/accounts/{acc['id']}",
        json={"balance": "8000", "monthly_income": "3000"},
    )
    assert resp.status_code == 200
    updated = resp.json()["data"]
    assert _dec(updated["balance"]) == Decimal("8000")
    assert _dec(updated["monthly_income"]) == Decimal("3000")

    resp = await client.delete(BASE.format(fid=fid) + f"/accounts/{acc['id']}")
    assert resp.status_code == 200
    listed = (await client.get(BASE.format(fid=fid) + "/accounts")).json()["data"]
    assert listed == []


async def test_debt_crud_and_from_account_validation(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # Linking a non-existent account is rejected.
    resp = await client.post(
        BASE.format(fid=fid) + "/debts",
        json={
            "name": "车贷",
            "balance": "100000",
            "monthly_payment": "3000",
            "payment_day": 8,
            "from_account_id": str(uuid.uuid4()),
        },
    )
    assert resp.status_code == 422, resp.text

    acc = await _add_account(client, fid)
    debt = await _add_debt(client, fid, from_account_id=acc["id"])
    assert debt["from_account_id"] == acc["id"]

    resp = await client.put(
        BASE.format(fid=fid) + f"/debts/{debt['id']}", json={"balance": "250000"}
    )
    assert _dec(resp.json()["data"]["balance"]) == Decimal("250000")

    resp = await client.delete(BASE.format(fid=fid) + f"/debts/{debt['id']}")
    assert resp.status_code == 200


async def test_plan_defaults_and_update(client: AsyncClient) -> None:
    fid = await _create_family(client)
    plan = (await client.get(BASE.format(fid=fid) + "/plan")).json()["data"]
    assert plan["retire_date"] is None
    assert plan["goal_basis"] == "net_worth"
    assert plan["surplus_basis"] == "income_debt_expense"

    plan = await _set_plan(
        client,
        fid,
        retire_date="2050-01-01",
        savings_goal="2000000",
        goal_basis="total_assets",
        surplus_basis="income_only",
    )
    assert plan["retire_date"] == "2050-01-01"
    assert plan["goal_basis"] == "total_assets"
    assert _dec(plan["savings_goal"]) == Decimal("2000000")


# ---- Dashboard math --------------------------------------------------------


async def test_dashboard_totals_and_bases(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _add_account(client, fid, kind="deposit", balance="100000", monthly_income="5000")
    await _add_account(client, fid, kind="fund", balance="50000", monthly_income="1000")
    await _add_debt(client, fid, balance="300000", monthly_payment="8000")

    await _set_plan(client, fid, goal_basis="net_worth", surplus_basis="income_debt")
    d = await _dashboard(client, fid)
    assert _dec(d["total_deposit"]) == Decimal("100000")
    assert _dec(d["total_fund"]) == Decimal("50000")
    assert _dec(d["total_assets"]) == Decimal("150000")
    assert _dec(d["total_debt"]) == Decimal("300000")
    assert _dec(d["net_worth"]) == Decimal("-150000")
    assert _dec(d["monthly_income"]) == Decimal("6000")
    assert _dec(d["monthly_debt"]) == Decimal("8000")
    # net_worth basis, income−debt surplus.
    assert _dec(d["current"]) == Decimal("-150000")
    assert _dec(d["monthly_surplus"]) == Decimal("-2000")

    await _set_plan(client, fid, goal_basis="total_assets")
    assert _dec((await _dashboard(client, fid))["current"]) == Decimal("150000")

    await _set_plan(client, fid, goal_basis="deposit_only")
    assert _dec((await _dashboard(client, fid))["current"]) == Decimal("100000")

    await _set_plan(client, fid, surplus_basis="income_only")
    assert _dec((await _dashboard(client, fid))["monthly_surplus"]) == Decimal("6000")


async def test_months_to_goal_and_monthly_gap(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # Empty deposit, ¥5000/mo income, no debt → surplus = 5000 (income_only).
    acc = await _add_account(
        client, fid, kind="deposit", balance="0", monthly_income="5000", income_day=1
    )
    await _set_plan(
        client,
        fid,
        goal_basis="deposit_only",
        surplus_basis="income_only",
        savings_goal="120000",
        retire_date=_months_ahead(12),
    )

    d = await _dashboard(client, fid)
    assert d["goal_reached"] is False
    # Requirement 6: 120000 / 5000 = 24 months.
    assert d["months_to_goal"] == 24
    assert d["months_to_retire"] == 12
    # Requirement 7: required 120000/12 = 10000; gap 5000−10000 = −5000 (green).
    assert _dec(d["required_monthly"]) == Decimal("10000")
    assert _dec(d["monthly_gap"]) == Decimal("-5000")

    # Triple the income → surplus 15000 > required → positive gap (red).
    await client.put(
        BASE.format(fid=fid) + f"/accounts/{acc['id']}",
        json={"monthly_income": "15000"},
    )
    d = await _dashboard(client, fid)
    assert d["months_to_goal"] == 8  # ceil(120000 / 15000)
    assert _dec(d["monthly_gap"]) == Decimal("5000")


async def test_goal_already_reached(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _add_account(
        client,
        fid,
        kind="deposit",
        balance="200000",
        monthly_income="5000",
        income_day=1,
    )
    await _set_plan(
        client,
        fid,
        goal_basis="deposit_only",
        surplus_basis="income_only",
        savings_goal="120000",
        retire_date=_months_ahead(12),
    )
    d = await _dashboard(client, fid)
    assert d["goal_reached"] is True
    assert d["months_to_goal"] == 0
    assert _dec(d["required_monthly"]) == Decimal("0")
    # Already past the goal → full surplus is a cushion (red +¥).
    assert _dec(d["monthly_gap"]) == Decimal("5000")


async def test_unreachable_when_surplus_non_positive(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _add_account(client, fid, kind="deposit", balance="0", monthly_income="0")
    await _add_debt(client, fid, balance="300000", monthly_payment="8000")
    await _set_plan(
        client,
        fid,
        goal_basis="deposit_only",
        surplus_basis="income_debt",
        savings_goal="120000",
    )
    d = await _dashboard(client, fid)
    assert _dec(d["monthly_surplus"]) == Decimal("-8000")
    assert d["months_to_goal"] is None  # can't get there at this rate


async def test_dashboard_without_plan_has_null_projection(client: AsyncClient) -> None:
    fid = await _create_family(client)
    await _add_account(client, fid, balance="1000")
    d = await _dashboard(client, fid)
    assert d["retire_date"] is None
    assert d["savings_goal"] is None
    assert d["months_to_goal"] is None
    assert d["months_to_retire"] is None
    assert d["goal_reached"] is False
