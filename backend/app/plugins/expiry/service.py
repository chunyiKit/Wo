"""Expiry business logic — read builder + home preview hook."""

from datetime import date
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.plugin import InstalledPlugin
from app.plugins.expiry.models import ExpiryItem, ExpiryItemRead
from app.plugins.registry import PluginPreview

# Card warns when within this many days of expiry; nothing special further out.
_WARNING_DAYS = 14


def build_read(row: ExpiryItem, today: date | None = None) -> ExpiryItemRead:
    """Serialize a row, injecting `days_until` (immutable copy)."""
    today = today or date.today()
    read = ExpiryItemRead.model_validate(row, from_attributes=True)
    return read.model_copy(update={"days_until": (row.expire_on - today).days})


def _due_text(delta: int) -> tuple[str, str | None]:
    """Card secondary text + tone for a days-until-expiry delta."""
    if delta < 0:
        return f"已过期 {-delta} 天", "danger"
    if delta == 0:
        return "今天到期", "danger"
    if delta == 1:
        return "明天到期", "warning"
    if delta <= _WARNING_DAYS:
        return f"{delta} 天后到期", "warning"
    return f"{delta} 天后到期", None


async def preview_hook(
    session: AsyncSession, ip: InstalledPlugin, _viewer_id: UUID | None = None
) -> PluginPreview:
    """Home card: the soonest-to-expire active item + how many days away."""
    stmt = select(ExpiryItem).where(
        ExpiryItem.family_id == ip.family_id,
        ExpiryItem.active.is_(True),
    )
    rows = list((await session.execute(stmt)).scalars().all())
    if not rows:
        return PluginPreview(
            primary="还没有记录",
            secondary="点击添加第一项",
            color_token="expiry",
            emoji="📄",
        )

    today = date.today()
    nxt = min(rows, key=lambda r: r.expire_on)
    delta = (nxt.expire_on - today).days
    secondary, tone = _due_text(delta)
    return PluginPreview(
        primary=nxt.name,
        secondary=secondary,
        color_token="expiry",
        secondary_tone=tone,
        emoji=nxt.emoji,
    )


__all__ = ["build_read", "preview_hook"]
