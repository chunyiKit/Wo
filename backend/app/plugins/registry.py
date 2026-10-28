"""Plugin registry — code-side metadata, routes, and preview hooks per plugin.

Each plugin's `__init__.py` calls `registry.register(...)` at import time. The
v1 API router then walks the registry to mount per-plugin routes, and the
home-card response composer asks the registry for each plugin's preview.

Static plugin metadata (name, emoji, description, default layout, permissions,
version, screenshots) lives in code (`PluginManifest`). Mutable runtime
aggregates (install_count, rating) live in the `plugins` table — see
`app.models.plugin`.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal
from typing import Literal
from uuid import UUID

from fastapi import APIRouter
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

PluginCategory = Literal["life", "finance", "health", "education", "entertainment"]
ColorToken = Literal[
    "photo",
    "money",
    "anniv",
    "chore",
    "pet",
    "memory",
    "stock",
    "movie",
    "calendar",
    "subscribe",
    "plant",
    "retire",
    "expiry",
    "travel",
    "accent",
]
# Optional emphasis applied to a card's `secondary` text. None = normal color.
SecondaryTone = Literal["warning", "danger"]


@dataclass(frozen=True)
class Permission:
    code: str
    label: str


@dataclass(frozen=True)
class DefaultLayout:
    """Default tile size when first-fit installing without explicit layout."""

    cw: int
    ch: int


@dataclass(frozen=True)
class PluginManifest:
    id: str
    name: str
    description_short: str
    description_long: str
    emoji: str
    category: PluginCategory
    color_token: ColorToken
    version: str
    publisher: str
    default_layout: DefaultLayout
    permissions: tuple[Permission, ...] = ()
    screenshots: tuple[str, ...] = ()
    size_kb: int = 0
    # When True, a family may install this plugin more than once (each card can
    # be configured independently via InstalledPlugin.config). Defaults to
    # single-install.
    multi_instance: bool = False
    # When False, the plugin's routes / preview still work for any family that
    # already had it installed, but the marketplace `/plugins` list hides it
    # so no new install can be triggered. Use for half-finished plugins or
    # plugins being retired — flip to True once the work is back on track.
    published: bool = True
    # Notification `type` values this plugin can emit (see app.services
    # .notification). Non-empty means the plugin has a notification mechanism,
    # so it shows up as a toggleable source on the user's 通知偏好 page.
    notification_types: tuple[str, ...] = ()


class TrendPoint(BaseModel):
    date: date
    value: Decimal


class BackgroundTrend(BaseModel):
    label: str
    unit: str
    points: list[TrendPoint]


class PluginPreview(BaseModel):
    """Home-card preview data each plugin renders. Returned by the preview hook."""

    primary: str
    secondary: str | None = None
    badge: str | None = None
    color_token: ColorToken
    # Emphasis for `secondary` (e.g. a budget running low). None = normal.
    secondary_tone: SecondaryTone | None = None
    # Big icon to show on the card. When None the client falls back to the
    # plugin's manifest emoji. Lets a card reflect content-specific emoji
    # (e.g. the chosen anniversary emoji rather than the plugin's 🎂).
    emoji: str | None = None
    # Optional thumbnails the home card can render in addition to the text
    # block — e.g. the memory plugin's 4×2 card carousels the latest photos
    # on its right half. Each entry is a host-relative URL (the client
    # prepends baseUrl and uses image auth headers). Empty / None = no
    # carousel; plugins that don't surface imagery just leave this unset.
    image_urls: list[str] | None = None
    # Optional time series painted behind the home-card content.
    background_trend: BackgroundTrend | None = None


# A preview hook receives the session, the installed-plugin row (so it can read
# per-card `config`, e.g. which anniversary this card is pinned to), and the id
# of the user the card is being rendered for (so a card can show viewer-specific
# data, e.g. how many chores *I* still owe). It returns a fresh preview. Plugins
# that don't register one fall back to a default.
# `ip` is typed as `object` to avoid a circular import with app.models.plugin;
# hooks annotate the concrete `InstalledPlugin` type themselves.
PreviewProvider = Callable[[AsyncSession, "object", "UUID | None"], Awaitable[PluginPreview]]

# 账号注销钩子（合规要求：注销后必须清除该用户的个人数据）。
#
# 为什么是钩子：用户数据散落在各个插件里（回忆的照片、记账的流水、宠物的记录…），
# 核心服务不可能知道每张表的形状。规则是 —— **谁创建的数据谁负责擦除**。
#
# 契约：
#   - 接收 (session, user_id)，删除该用户在该插件里的全部数据**行**
#   - 返回需要一并删除的**存储对象 key 列表**（照片/视频等二进制）
#     由调用方在事务提交后统一清理：提交前删对象，万一事务回滚就删错了
#   - 不要自己 commit，事务由调用方控制
#   - 不实现即视为该插件不持有用户数据（17 个插件里绝大多数如此）
EraseUserHook = Callable[[AsyncSession, UUID], Awaitable[list[str]]]


@dataclass
class PluginRegistration:
    manifest: PluginManifest
    router: APIRouter | None = None
    preview: PreviewProvider | None = None
    erase_user: EraseUserHook | None = None
    # Reserved for future hooks (uninstall cleanup, config validators, etc.).
    extras: dict[str, object] = field(default_factory=dict)


class PluginRegistry:
    """Process-wide singleton — built once at import time, read at request time."""

    def __init__(self) -> None:
        self._regs: dict[str, PluginRegistration] = {}

    def register(
        self,
        manifest: PluginManifest,
        router: APIRouter | None = None,
        preview: PreviewProvider | None = None,
        erase_user: EraseUserHook | None = None,
    ) -> None:
        if manifest.id in self._regs:
            raise RuntimeError(f"Plugin {manifest.id!r} already registered")
        self._regs[manifest.id] = PluginRegistration(
            manifest=manifest, router=router, preview=preview, erase_user=erase_user
        )

    def erase_user_hooks(self) -> list[EraseUserHook]:
        """所有实现了注销擦除的插件钩子。"""
        return [r.erase_user for r in self._regs.values() if r.erase_user]

    def get(self, plugin_id: str) -> PluginRegistration | None:
        return self._regs.get(plugin_id)

    def get_manifest(self, plugin_id: str) -> PluginManifest | None:
        reg = self._regs.get(plugin_id)
        return reg.manifest if reg else None

    def list_manifests(self) -> list[PluginManifest]:
        return [r.manifest for r in self._regs.values()]

    def list_registrations(self) -> list[PluginRegistration]:
        return list(self._regs.values())


registry = PluginRegistry()
