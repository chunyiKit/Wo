"""Stock (囤货铺) plugin tables.

Two linked resources:

- `StockItem` (`stock_items`) — something the family keeps stocked at home,
  with a current quantity. When `low_at` is set and `qty <= low_at`, the item
  is "running low" and the home card nudges the family to restock.
- `BuyItem` (`stock_buys`) — a line on the shared shopping list. It can be
  born from a low stock item (`stock_item_id` points back), and when marked
  bought it can flow its quantity back into stock — closing the loop between
  "采买备忘" and "家庭囤货".

Tables are plugin-prefixed (`stock_*`) like `chore_chores` / `recipe_recipes`.
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import Column, DateTime
from sqlmodel import Field, SQLModel

from app.core.ids import new_uuid7

MAX_NAME_LEN = 64
MAX_UNIT_LEN = 16
MAX_NOTE_LEN = 500
MAX_WANT_LEN = 32


# ── 囤货库存 ──────────────────────────────────────────────────────────


class StockItemBase(SQLModel):
    name: str = Field(max_length=MAX_NAME_LEN)
    emoji: str = Field(default="📦", max_length=16)
    qty: int = Field(default=0, ge=0)
    unit: str | None = Field(default=None, max_length=MAX_UNIT_LEN)
    # When set, qty <= low_at means "running low". None = never alerts.
    low_at: int | None = Field(default=None, ge=0)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)


class StockItem(StockItemBase, table=True):
    __tablename__ = "stock_items"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    created_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )


class StockItemCreate(StockItemBase):
    """POST request body."""


class StockItemUpdate(SQLModel):
    """PUT request body — all fields optional for partial update."""

    name: str | None = Field(default=None, max_length=MAX_NAME_LEN)
    emoji: str | None = Field(default=None, max_length=16)
    qty: int | None = Field(default=None, ge=0)
    unit: str | None = Field(default=None, max_length=MAX_UNIT_LEN)
    low_at: int | None = Field(default=None, ge=0)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)


class StockItemRead(StockItemBase):
    id: UUID
    family_id: UUID
    created_at: datetime
    created_by: UUID | None
    # Convenience flag computed server-side: low_at is set and qty <= low_at.
    is_low: bool = False


# ── 采买待买清单 ──────────────────────────────────────────────────────


class BuyItemBase(SQLModel):
    name: str = Field(max_length=MAX_NAME_LEN)
    emoji: str = Field(default="🛒", max_length=16)
    # Free text — "2 瓶", "一大袋", etc. Kept as text on purpose.
    want_qty: str | None = Field(default=None, max_length=MAX_WANT_LEN)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)


class BuyItem(BuyItemBase, table=True):
    __tablename__ = "stock_buys"

    id: UUID = Field(default_factory=new_uuid7, primary_key=True)
    family_id: UUID = Field(
        foreign_key="families.id",
        ondelete="CASCADE",
        index=True,
    )
    # The stock item this line was raised for, if any. SET NULL so the buy line
    # survives the stock item being deleted; it just loses the back-link.
    stock_item_id: UUID | None = Field(
        default=None,
        foreign_key="stock_items.id",
        ondelete="SET NULL",
        nullable=True,
        index=True,
    )
    bought: bool = Field(default=False)
    bought_at: datetime | None = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True),
    )
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(UTC),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    created_by: UUID | None = Field(
        default=None,
        foreign_key="users.id",
        ondelete="SET NULL",
        nullable=True,
    )


class BuyItemCreate(BuyItemBase):
    """POST request body."""


class BuyItemUpdate(SQLModel):
    """PUT request body — all fields optional for partial update."""

    name: str | None = Field(default=None, max_length=MAX_NAME_LEN)
    emoji: str | None = Field(default=None, max_length=16)
    want_qty: str | None = Field(default=None, max_length=MAX_WANT_LEN)
    note: str | None = Field(default=None, max_length=MAX_NOTE_LEN)
    bought: bool | None = None


class BuyItemRead(BuyItemBase):
    id: UUID
    family_id: UUID
    stock_item_id: UUID | None
    bought: bool
    bought_at: datetime | None
    created_at: datetime
    created_by: UUID | None


class MarkBoughtBody(SQLModel):
    """`POST /buys/{id}/bought` body. When `into_stock_qty` is given the bought
    item flows that many units into stock: bumping the linked stock item, or
    creating a fresh one from this buy line when there's no link."""

    into_stock_qty: int | None = Field(default=None, ge=0)
