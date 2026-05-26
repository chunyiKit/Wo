"""Shared response composers for the plugin platform.

Routes that need to return an `InstalledPluginRead` (the per-family list
endpoint, the install endpoint, and the `/me/bootstrap` aggregator) all
build the embedded `plugin` snapshot, the layout, and the live preview via
the same helpers — this keeps the JSON shape identical across routes and
prevents one endpoint from drifting from another.

`to_installed_read` is the only function callers usually need. The smaller
helpers are exported in case a route wants finer control.
"""

from uuid import UUID

from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import AppError, ErrorCode
from app.models.plugin import InstalledPlugin, Plugin
from app.plugins.registry import (
    ColorToken,
    PluginCategory,
    PluginManifest,
    PluginPreview,
    PluginRegistration,
    registry,
)


class PermissionRead(BaseModel):
    code: str
    label: str


class PluginRead(BaseModel):
    id: str
    name: str
    description_short: str
    description_long: str
    emoji: str
    category: PluginCategory
    color_token: ColorToken
    version: str
    publisher: str
    permissions: list[PermissionRead]
    screenshots: list[str]
    size_kb: int
    rating: float
    install_count: int
    multi_instance: bool


class LayoutRead(BaseModel):
    col: int
    row: int
    cw: int
    ch: int


class InstalledPluginRead(BaseModel):
    id: UUID
    family_id: UUID
    plugin_id: str
    plugin: PluginRead
    enabled: bool
    layout: LayoutRead
    config: dict
    preview: PluginPreview
    installed_at: object  # datetime — kept loose so pydantic serializes naturally
    installed_by: UUID | None


def to_plugin_read(manifest: PluginManifest, db_plugin: Plugin) -> PluginRead:
    return PluginRead(
        id=manifest.id,
        name=manifest.name,
        description_short=manifest.description_short,
        description_long=manifest.description_long,
        emoji=manifest.emoji,
        category=manifest.category,
        color_token=manifest.color_token,
        version=db_plugin.current_version or manifest.version,
        publisher=manifest.publisher,
        permissions=[PermissionRead(code=p.code, label=p.label) for p in manifest.permissions],
        screenshots=list(manifest.screenshots),
        size_kb=manifest.size_kb,
        rating=db_plugin.rating,
        install_count=db_plugin.install_count,
        multi_instance=manifest.multi_instance,
    )


async def compute_preview(
    session: AsyncSession,
    ip: InstalledPlugin,
    reg: PluginRegistration,
    viewer_id: UUID | None = None,
) -> PluginPreview:
    """Call the plugin's preview hook; degrade to plugin name on any error.

    `viewer_id` is the user the card is rendered for, letting a hook surface
    viewer-specific data (e.g. the chore plugin shows *my* outstanding count).
    """
    if reg.preview is not None:
        try:
            return await reg.preview(session, ip, viewer_id)
        except Exception:
            # Preview must never crash the home request.
            pass
    return PluginPreview(primary=reg.manifest.name, color_token=reg.manifest.color_token)


async def to_installed_read(
    session: AsyncSession,
    ip: InstalledPlugin,
    viewer_id: UUID | None = None,
) -> InstalledPluginRead:
    reg = registry.get(ip.plugin_id)
    if reg is None:
        raise AppError(
            ErrorCode.INTERNAL,
            f"已安装插件 {ip.plugin_id} 在 registry 中找不到（代码已下架？）",
            status_code=500,
        )
    db_plugin = await session.get(Plugin, ip.plugin_id)
    if db_plugin is None:
        raise AppError(
            ErrorCode.INTERNAL,
            f"plugins 表里没有 {ip.plugin_id} 的聚合行，运行 ensure_plugins 修复",
            status_code=500,
        )
    return InstalledPluginRead(
        id=ip.id,
        family_id=ip.family_id,
        plugin_id=ip.plugin_id,
        plugin=to_plugin_read(reg.manifest, db_plugin),
        enabled=ip.enabled,
        layout=LayoutRead(col=ip.col, row=ip.row, cw=ip.cw, ch=ip.ch),
        config=ip.config or {},
        preview=await compute_preview(session, ip, reg, viewer_id),
        installed_at=ip.installed_at,
        installed_by=ip.installed_by,
    )
