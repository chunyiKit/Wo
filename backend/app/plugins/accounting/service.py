"""Accounting business logic — month aggregation, budget, and the home preview."""

from datetime import UTC, date, datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.plugin import InstalledPlugin
from app.plugins.accounting.models import Budget, Transaction, TransactionRead
from app.plugins.registry import PluginPreview
from app.services.membership import MemberInfo, author_avatar_url

# Below this fraction of budget remaining the card warns; below the second it
# alarms. Matches the product spec: <40% yellow, <10% red.
_WARNING_RATIO = 0.4
_DANGER_RATIO = 0.1


def month_bounds(year: int, month: int) -> tuple[datetime, datetime]:
    """[start, end) UTC instants spanning the given calendar month."""
    start = datetime(year, month, 1, tzinfo=UTC)
    end = (
        datetime(year + 1, 1, 1, tzinfo=UTC)
        if month == 12
        else datetime(year, month + 1, 1, tzinfo=UTC)
    )
    return start, end


async def month_total(
    session: AsyncSession,
    family_id: UUID,
    year: int | None = None,
    month: int | None = None,
) -> Decimal:
    """Sum of this family's expenses in the given month (defaults to current)."""
    today = date.today()
    start, end = month_bounds(year or today.year, month or today.month)
    stmt = select(func.coalesce(func.sum(Transaction.amount), 0)).where(
        Transaction.family_id == family_id,
        Transaction.created_at >= start,
        Transaction.created_at < end,
    )
    return Decimal((await session.execute(stmt)).scalar_one())


async def get_budget(session: AsyncSession, family_id: UUID) -> Decimal | None:
    """The family's recurring monthly budget, or None if unset."""
    row = await session.get(Budget, family_id)
    return row.monthly_amount if row is not None else None


def build_read(row: Transaction, members: dict[UUID, MemberInfo]) -> TransactionRead:
    """Serialize a row, injecting recorder display info (immutable copy)."""
    read = TransactionRead.model_validate(row, from_attributes=True)
    info = members.get(row.created_by) if row.created_by is not None else None
    return read.model_copy(
        update={
            "creator_name": info.name if info else None,
            "creator_emoji": info.emoji if info else None,
            "creator_avatar_url": author_avatar_url(
                row.family_id, row.created_by, info
            ),
        }
    )


def _fmt(amount: Decimal) -> str:
    """Render money for the card, dropping a trailing .00 for whole amounts."""
    quantized = amount.quantize(Decimal("0.01"))
    if quantized == quantized.to_integral_value():
        return f"¥{int(quantized)}"
    return f"¥{quantized}"


async def preview_hook(
    session: AsyncSession, ip: InstalledPlugin, _viewer_id: UUID | None = None
) -> PluginPreview:
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
