"""Subscription business logic — cycle date math, read builder, preview hook."""

from calendar import monthrange
from datetime import date
from decimal import Decimal
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.plugin import InstalledPlugin
from app.plugins.registry import PluginPreview
from app.plugins.subscription.models import Subscription, SubscriptionRead


def _clamp_day(year: int, month: int, day: int) -> date:
    """A valid date for (year, month, day), clamping day to the month length so
    a 31st-of-the-month bill lands on the 30th/28th in shorter months."""
    last = monthrange(year, month)[1]
    return date(year, month, min(day, last))


def format_amount(amount: Decimal) -> str:
    """¥ with no decimals for whole amounts, two otherwise."""
    if amount == amount.to_integral():
        return f"¥{amount:.0f}"
    return f"¥{amount:.2f}"


def advance_due(current: date, cycle: str) -> date:
    """The next due date one cycle after `current` (monthly or yearly)."""
    if cycle == "yearly":
        # Feb-29 → Feb-28 on common years via the clamp.
        return _clamp_day(current.year + 1, current.month, current.day)
    # monthly (default)
    if current.month == 12:
        return _clamp_day(current.year + 1, 1, current.day)
    return _clamp_day(current.year, current.month + 1, current.day)


def build_read(row: Subscription, today: date | None = None) -> SubscriptionRead:
    """Serialize a row, injecting `days_until` (immutable copy)."""
    today = today or date.today()
    read = SubscriptionRead.model_validate(row, from_attributes=True)
    return read.model_copy(update={"days_until": (row.next_due - today).days})


async def preview_hook(
    session: AsyncSession, ip: InstalledPlugin, _viewer_id: UUID | None = None
) -> PluginPreview:
    """Home card: the soonest-due active subscription + how many days away."""
    stmt = select(Subscription).where(
        Subscription.family_id == ip.family_id,
        Subscription.active.is_(True),
    )
    rows = list((await session.execute(stmt)).scalars().all())
    if not rows:
        return PluginPreview(
            primary="还没有订阅",
            secondary="点击添加第一笔",
            color_token="subscribe",
            emoji="💳",
        )

    today = date.today()
    nxt = min(rows, key=lambda r: r.next_due)
    delta = (nxt.next_due - today).days
    amount = format_amount(nxt.amount)
    if delta < 0:
        secondary, tone = "已过期待扣费", "danger"
    elif delta == 0:
        secondary, tone = f"今天扣费 {amount}", "warning"
    elif delta <= 3:
        secondary, tone = f"{delta} 天后扣 {amount}", "warning"
    else:
        secondary, tone = f"{delta} 天后扣 {amount}", None
    return PluginPreview(
        primary=nxt.name,
        secondary=secondary,
        color_token="subscribe",
        secondary_tone=tone,
        emoji=nxt.emoji,
    )


__all__ = ["advance_due", "build_read", "preview_hook"]
