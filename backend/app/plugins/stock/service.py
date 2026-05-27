"""Stock business logic — is-low computation + home-card preview."""

from uuid import UUID

from sqlalchemy import func
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.plugin import InstalledPlugin
from app.plugins.registry import PluginPreview
from app.plugins.stock.models import BuyItem, BuyItemRead, StockItem, StockItemRead


def is_low(item: StockItem) -> bool:
    """True when the item has a threshold and its quantity has reached it."""
    return item.low_at is not None and item.qty <= item.low_at


def build_stock_read(row: StockItem) -> StockItemRead:
    read = StockItemRead.model_validate(row, from_attributes=True)
    return read.model_copy(update={"is_low": is_low(row)})


def build_buy_read(row: BuyItem) -> BuyItemRead:
    return BuyItemRead.model_validate(row, from_attributes=True)


async def _low_count(session: AsyncSession, family_id: UUID) -> int:
    """How many stock items are at or below their low threshold."""
    stmt = (
        select(func.count())
        .select_from(StockItem)
        .where(
            StockItem.family_id == family_id,
            StockItem.low_at.is_not(None),
            StockItem.qty <= StockItem.low_at,
        )
    )
    return int((await session.execute(stmt)).scalar_one())


async def _open_buys_count(session: AsyncSession, family_id: UUID) -> int:
    """How many shopping-list lines are still unbought."""
    stmt = (
        select(func.count())
        .select_from(BuyItem)
        .where(BuyItem.family_id == family_id, BuyItem.bought.is_(False))
    )
    return int((await session.execute(stmt)).scalar_one())


async def preview_hook(
    session: AsyncSession, ip: InstalledPlugin, viewer_id: UUID | None = None
) -> PluginPreview:
    """Home card: nudge to restock when something's low, else show the open
    shopping list, else celebrate a stocked, cleared-out home."""
    low = await _low_count(session, ip.family_id)
    if low > 0:
        return PluginPreview(
            primary=f"{low} 样要补货",
            secondary="该去采买啦",
            color_token="stock",
            secondary_tone="warning",
            badge=str(low),
            emoji="🛒",
        )

    open_buys = await _open_buys_count(session, ip.family_id)
    if open_buys > 0:
        return PluginPreview(
            primary=f"采买清单 {open_buys} 项",
            secondary="还没买齐",
            color_token="stock",
            badge=str(open_buys),
            emoji="🛒",
        )

    return PluginPreview(
        primary="囤货充足",
        secondary="清单已清空 ✨",
        color_token="stock",
        emoji="🛒",
    )
