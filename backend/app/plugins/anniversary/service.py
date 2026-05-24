"""Anniversary business logic — preview hook + helpers."""

from datetime import date
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.plugins.anniversary.models import Anniversary
from app.plugins.registry import PluginPreview


def _days_until(target: date, today: date) -> int:
    """Days from `today` to this year's (or next year's) occurrence of `target`."""
    this_year = target.replace(year=today.year)
    if this_year < today:
        this_year = target.replace(year=today.year + 1)
    return (this_year - today).days


async def preview_hook(session: AsyncSession, family_id: UUID) -> PluginPreview:
    """Surface the next-upcoming anniversary on the family's home card."""
    stmt = select(Anniversary).where(Anniversary.family_id == family_id)
    rows = list((await session.execute(stmt)).scalars().all())

    if not rows:
        return PluginPreview(
            primary="还没有记录",
            secondary="点击添加第一个纪念日",
            color_token="anniv",
        )

    today = date.today()
    next_one = min(rows, key=lambda r: _days_until(r.event_date, today))
    delta = _days_until(next_one.event_date, today)
    secondary = "就是今天 🎉" if delta == 0 else f"还有 {delta} 天"
    return PluginPreview(
        primary=f"{next_one.emoji} {next_one.name}",
        secondary=secondary,
        color_token="anniv",
    )
