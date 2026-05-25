"""Accounting business logic — month aggregation, budget, and the home preview."""

from datetime import UTC, date, datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.membership import Membership
from app.models.plugin import InstalledPlugin
from app.plugins.accounting.models import Budget, Transaction, TransactionRead
from app.plugins.registry import PluginPreview

# Below this fraction of budget remaining the card warns; below the second it
# alarms. Matches the product spec: <40% yellow, <10% red.
_WARNING_RATIO = 0.4
_DANGER_RATIO = 0.1


def _month_start(today: date) -> datetime:
    """First instant of the current calendar month (UTC, tz-aware)."""
    return datetime(today.year, today.month, 1, tzinfo=UTC)


async def month_total(
    session: AsyncSession, family_id: UUID, today: date | None = None
) -> Decimal:
    """Sum of this family's expenses recorded in the current month."""
    today = today or date.today()
    stmt = select(func.coalesce(func.sum(Transaction.amount), 0)).where(
        Transaction.family_id == family_id,
        Transaction.created_at >= _month_start(today),
    )
    return Decimal((await session.execute(stmt)).scalar_one())


async def get_budget(session: AsyncSession, family_id: UUID) -> Decimal | None:
    """The family's recurring monthly budget, or None if unset."""
    row = await session.get(Budget, family_id)
    return row.monthly_amount if row is not None else None


async def member_map(
    session: AsyncSession, family_id: UUID
) -> dict[UUID, tuple[str, str]]:
    """Map user_id → (display_name, avatar_emoji) for a family's members."""
    stmt = select(Membership).where(Membership.family_id == family_id)
    rows = (await session.execute(stmt)).scalars().all()
    return {m.user_id: (m.display_name, m.avatar_emoji) for m in rows}


def build_read(
    row: Transaction, members: dict[UUID, tuple[str, str]]
) -> TransactionRead:
    """Serialize a row, injecting recorder display info (immutable copy)."""
    read = TransactionRead.model_validate(row, from_attributes=True)
    name, emoji = (None, None)
    if row.created_by is not None and row.created_by in members:
        name, emoji = members[row.created_by]
    return read.model_copy(update={"creator_name": name, "creator_emoji": emoji})


def _fmt(amount: Decimal) -> str:
    """Render money for the card, dropping a trailing .00 for whole amounts."""
    quantized = amount.quantize(Decimal("0.01"))
    if quantized == quantized.to_integral_value():
        return f"¥{int(quantized)}"
    return f"¥{quantized}"


async def preview_hook(session: AsyncSession, ip: InstalledPlugin) -> PluginPreview:
    """Render the home card for the accounting widget.

    A compact (2×1) card shows only this month's total; a standard (2×2) card
    also shows the remaining budget, whose number turns yellow below 40% and
    red below 10% of budget.
    """
    total = await month_total(session, ip.family_id)

    if ip.ch <= 1:
        return PluginPreview(
            primary=_fmt(total),
            secondary="本月支出",
            color_token="money",
            emoji="💰",
        )

    budget = await get_budget(session, ip.family_id)
    if budget is None or budget <= 0:
        return PluginPreview(
            primary=_fmt(total),
            secondary="未设预算",
            color_token="money",
            emoji="💰",
        )

    remaining = budget - total
    ratio = float(remaining / budget)
    tone: str | None = None
    if ratio < _DANGER_RATIO:
        tone = "danger"
    elif ratio < _WARNING_RATIO:
        tone = "warning"

    return PluginPreview(
        primary=_fmt(total),
        secondary=f"剩余 {_fmt(remaining)}",
        secondary_tone=tone,
        color_token="money",
        emoji="💰",
    )
