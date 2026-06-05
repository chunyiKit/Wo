"""Retirement business logic — month math, dashboard projection, preview hook.

The dashboard is the heart of the plugin (requirements 6 & 7). All money is
`Decimal`; the two "basis" toggles on the family's plan decide what the goal is
measured against and how the monthly surplus is composed.
"""

from datetime import date
from decimal import ROUND_CEILING, Decimal
from uuid import UUID

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.plugin import InstalledPlugin
from app.plugins.accounting.service import get_budget, month_total
from app.plugins.registry import PluginPreview
from app.plugins.retirement.models import (
    RetireAccount,
    RetireAccountRead,
    RetireDashboardRead,
    RetireDebt,
    RetireDebtRead,
    RetireLedger,
    RetireLedgerRead,
    RetirePlan,
)
from app.services.membership import MemberInfo, author_avatar_url

ACCOUNTING_PLUGIN_ID = "accounting"
RETIREMENT_PLUGIN_ID = "retirement"
_ZERO = Decimal("0")
_CENT = Decimal("0.01")


def prev_month(year: int, month: int) -> tuple[int, int]:
    """The (year, month) immediately before the given calendar month."""
    return (year - 1, 12) if month == 1 else (year, month - 1)


def format_amount(amount: Decimal) -> str:
    """¥ with no decimals for whole amounts, two otherwise."""
    if amount == amount.to_integral_value():
        return f"¥{amount:.0f}"
    return f"¥{amount:.2f}"


def _sum(values: list[Decimal]) -> Decimal:
    total = _ZERO
    for v in values:
        total += v
    return total


# ── Read builders (inject recorder avatar — see CLAUDE.md) ────────────────────


def build_account_read(row: RetireAccount, members: dict[UUID, MemberInfo]) -> RetireAccountRead:
    read = RetireAccountRead.model_validate(row, from_attributes=True)
    info = members.get(row.created_by) if row.created_by is not None else None
    return read.model_copy(
        update={
            "creator_name": info.name if info else None,
            "creator_emoji": info.emoji if info else None,
            "creator_avatar_url": author_avatar_url(row.family_id, row.created_by, info),
        }
    )


def build_debt_read(row: RetireDebt, members: dict[UUID, MemberInfo]) -> RetireDebtRead:
    read = RetireDebtRead.model_validate(row, from_attributes=True)
    info = members.get(row.created_by) if row.created_by is not None else None
    return read.model_copy(
        update={
            "creator_name": info.name if info else None,
            "creator_emoji": info.emoji if info else None,
            "creator_avatar_url": author_avatar_url(row.family_id, row.created_by, info),
        }
    )


def build_ledger_read(row: RetireLedger) -> RetireLedgerRead:
    return RetireLedgerRead.model_validate(row, from_attributes=True)


# ── Cross-plugin / data helpers ───────────────────────────────────────────────


async def accounting_installed(session: AsyncSession, family_id: UUID) -> bool:
    stmt = (
        select(func.count())
        .select_from(InstalledPlugin)
        .where(
            InstalledPlugin.family_id == family_id,
            InstalledPlugin.plugin_id == ACCOUNTING_PLUGIN_ID,
        )
    )
    return int((await session.execute(stmt)).scalar_one()) > 0


async def expense_estimate(
    session: AsyncSession, family_id: UUID, year: int, month: int
) -> Decimal:
    """A representative monthly living-expense figure for the projection.

    Reads the accounting plugin's total for the previous full month; falls back
    to the recurring budget, then to 0. The cross-plugin tie-in (requirement:
    integrate with 记账).
    """
    py, pm = prev_month(year, month)
    total = await month_total(session, family_id, year=py, month=pm)
    if total > 0:
        return total
    budget = await get_budget(session, family_id)
    return budget if budget is not None else _ZERO


async def get_accounts(session: AsyncSession, family_id: UUID) -> list[RetireAccount]:
    stmt = (
        select(RetireAccount)
        .where(RetireAccount.family_id == family_id)
        .order_by(RetireAccount.created_at.asc())
    )
    return list((await session.execute(stmt)).scalars().all())


async def get_active_debts(session: AsyncSession, family_id: UUID) -> list[RetireDebt]:
    stmt = select(RetireDebt).where(
        RetireDebt.family_id == family_id,
        RetireDebt.active.is_(True),
    )
    return list((await session.execute(stmt)).scalars().all())


# ── Dashboard (requirements 6 & 7) ────────────────────────────────────────────


async def compute_dashboard(
    session: AsyncSession, family_id: UUID, *, today: date | None = None
) -> RetireDashboardRead:
    """Aggregate balances + flows and project the path to the retirement goal.

    `today` is injectable so tests stay deterministic.
    """
    today = today or date.today()

    accounts = await get_accounts(session, family_id)
    debts = await get_active_debts(session, family_id)

    total_deposit = _sum([a.balance for a in accounts if a.kind == "deposit"])
    total_fund = _sum([a.balance for a in accounts if a.kind == "fund"])
    total_assets = total_deposit + total_fund
    total_debt = _sum([d.balance for d in debts])
    net_worth = total_assets - total_debt

    monthly_income = _sum([a.monthly_income for a in accounts])
    monthly_debt = _sum([d.monthly_payment for d in debts])

    plan = await session.get(RetirePlan, family_id)
    goal_basis = plan.goal_basis if plan else "net_worth"
    surplus_basis = plan.surplus_basis if plan else "income_debt_expense"

    installed = await accounting_installed(session, family_id)
    monthly_expense = _ZERO
    if surplus_basis == "income_debt_expense":
        monthly_expense = await expense_estimate(session, family_id, today.year, today.month)

    current = {
        "net_worth": net_worth,
        "total_assets": total_assets,
        "deposit_only": total_deposit,
    }.get(goal_basis, net_worth)

    if surplus_basis == "income_only":
        monthly_surplus = monthly_income
    elif surplus_basis == "income_debt":
        monthly_surplus = monthly_income - monthly_debt
    else:
        monthly_surplus = monthly_income - monthly_debt - monthly_expense

    dash = RetireDashboardRead(
        total_deposit=total_deposit,
        total_fund=total_fund,
        total_assets=total_assets,
        total_debt=total_debt,
        net_worth=net_worth,
        current=current,
        monthly_income=monthly_income,
        monthly_debt=monthly_debt,
        monthly_expense=monthly_expense,
        monthly_surplus=monthly_surplus,
        goal_basis=goal_basis,
        surplus_basis=surplus_basis,
        accounting_installed=installed,
    )

    if plan is None:
        return dash

    updates: dict[str, object] = {}
    if plan.retire_date is not None:
        updates["retire_date"] = plan.retire_date
        updates["days_to_retire"] = (plan.retire_date - today).days
        updates["months_to_retire"] = max(
            0,
            (plan.retire_date.year - today.year) * 12 + (plan.retire_date.month - today.month),
        )

    if plan.savings_goal is not None:
        goal = plan.savings_goal
        remaining = goal - current
        reached = current >= goal
        updates["savings_goal"] = goal
        updates["remaining"] = remaining
        updates["goal_reached"] = reached
        # Requirement 6: months to reach the goal at the current surplus rate.
        if reached:
            updates["months_to_goal"] = 0
        elif monthly_surplus <= 0:
            updates["months_to_goal"] = None  # unreachable at this rate
        else:
            updates["months_to_goal"] = int(
                (remaining / monthly_surplus).to_integral_value(rounding=ROUND_CEILING)
            )

    if plan.retire_date is not None and plan.savings_goal is not None:
        months_left = updates["months_to_retire"]
        remaining = updates["remaining"]
        if months_left and months_left > 0:
            required = (max(_ZERO, remaining) / months_left).quantize(_CENT)
            # Requirement 7: positive → cushion (client +¥ red); negative →
            # income must rise by |gap| (client −¥ green).
            updates["required_monthly"] = required
            updates["monthly_gap"] = (monthly_surplus - required).quantize(_CENT)

    return dash.model_copy(update=updates)


# ── Home-card preview ─────────────────────────────────────────────────────────


def _countdown_text(days: int) -> str:
    if days <= 0:
        return "🎉 可以退休啦"
    years, rem = divmod(days, 365)
    months = rem // 30
    if years > 0:
        return f"距退休 {years} 年" + (f" {months} 个月" if months else "")
    if months > 0:
        return f"距退休 {months} 个月"
    return f"距退休 {days} 天"


async def preview_hook(
    session: AsyncSession, ip: InstalledPlugin, _viewer_id: UUID | None = None
) -> PluginPreview:
    """Home card: retirement countdown + goal-progress percentage."""
    dash = await compute_dashboard(session, ip.family_id)

    if dash.retire_date is None and dash.savings_goal is None:
        return PluginPreview(
            primary="未设退休目标",
            secondary="点击规划退休生活",
            color_token="retire",
            emoji="🏖️",
        )

    if dash.retire_date is not None:
        primary = _countdown_text(dash.days_to_retire or 0)
    else:
        primary = "退休规划"

    secondary: str | None
    tone: str | None = None
    if dash.savings_goal is not None and dash.savings_goal > 0:
        pct = int(dash.current / dash.savings_goal * 100)
        secondary = f"目标进度 {max(0, pct)}%"
        # Behind schedule (income needs to rise) → gentle warning tint.
        if dash.monthly_gap is not None and dash.monthly_gap < 0:
            tone = "warning"
    else:
        secondary = "未设存款目标"

    return PluginPreview(
        primary=primary,
        secondary=secondary,
        secondary_tone=tone,
        color_token="retire",
        emoji="🏖️",
    )


__all__ = [
    "accounting_installed",
    "build_account_read",
    "build_debt_read",
    "build_ledger_read",
    "compute_dashboard",
    "expense_estimate",
    "format_amount",
    "get_accounts",
    "get_active_debts",
    "preview_hook",
    "prev_month",
]
