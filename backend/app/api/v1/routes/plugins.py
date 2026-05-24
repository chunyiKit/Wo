"""Plugin platform routes — marketplace + per-family install/uninstall/layout.

Response shapes (`PluginRead`, `InstalledPluginRead`, `LayoutRead`) live in
`app.plugins.views` so the bootstrap endpoint can reuse them.

Two routers because the URL hierarchies differ — both are mounted in
`app.api.v1.router`.
"""

from uuid import UUID

from fastapi import APIRouter
from pydantic import BaseModel, Field
from sqlmodel import select

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_membership
from app.core.response import ApiResponse, ok
from app.models.plugin import InstalledPlugin, Plugin
from app.plugins.registry import registry
from app.plugins.views import (
    InstalledPluginRead,
    LayoutRead,
    PluginRead,
    to_installed_read,
    to_plugin_read,
)
from app.services import plugin as plugin_service

marketplace_router = APIRouter(prefix="/plugins", tags=["marketplace"])
installed_router = APIRouter(prefix="/families", tags=["plugins"])


# ---- Marketplace ----------------------------------------------------------


@marketplace_router.get("", response_model=ApiResponse[list[PluginRead]])
async def list_plugins(session: SessionDep) -> ApiResponse[list[PluginRead]]:
    manifests = registry.list_manifests()
    if not manifests:
        return ok([])
    stmt = select(Plugin).where(Plugin.id.in_([m.id for m in manifests]))
    rows = (await session.execute(stmt)).scalars().all()
    by_id = {p.id: p for p in rows}
    return ok([to_plugin_read(m, by_id[m.id]) for m in manifests if m.id in by_id])


@marketplace_router.get("/{plugin_id}", response_model=ApiResponse[PluginRead])
async def get_plugin(
    plugin_id: str,
    session: SessionDep,
) -> ApiResponse[PluginRead]:
    manifest = registry.get_manifest(plugin_id)
    db_plugin = await session.get(Plugin, plugin_id)
    if manifest is None or db_plugin is None:
        raise AppError(
            ErrorCode.NOT_FOUND,
            f"插件不存在：{plugin_id}",
            status_code=404,
        )
    return ok(to_plugin_read(manifest, db_plugin))


# ---- Installed plugins (per family) ---------------------------------------


@installed_router.get(
    "/{family_id}/plugins",
    response_model=ApiResponse[list[InstalledPluginRead]],
)
async def list_installed(
    family_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[InstalledPluginRead]]:
    await require_membership(session, current_user.id, family_id)
    stmt = (
        select(InstalledPlugin)
        .where(InstalledPlugin.family_id == family_id)
        .order_by(InstalledPlugin.row, InstalledPlugin.col)
    )
    rows = (await session.execute(stmt)).scalars().all()
    return ok([await to_installed_read(session, r) for r in rows])


class InstallRequest(BaseModel):
    plugin_id: str
    layout: LayoutRead | None = None


@installed_router.post(
    "/{family_id}/plugins",
    response_model=ApiResponse[InstalledPluginRead],
    status_code=201,
)
async def install_endpoint(
    family_id: UUID,
    payload: InstallRequest,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[InstalledPluginRead]:
    layout_tuple = (
        (payload.layout.col, payload.layout.row, payload.layout.cw, payload.layout.ch)
        if payload.layout is not None
        else None
    )
    ip = await plugin_service.install_plugin(
        session,
        family_id=family_id,
        plugin_id=payload.plugin_id,
        actor=current_user,
        layout=layout_tuple,
    )
    return ok(await to_installed_read(session, ip))


@installed_router.delete(
    "/{family_id}/plugins/{install_id}",
    response_model=ApiResponse[dict],
)
async def uninstall_endpoint(
    family_id: UUID,
    install_id: UUID,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[dict]:
    await plugin_service.uninstall_plugin(
        session,
        family_id=family_id,
        install_id=install_id,
        actor=current_user,
    )
    return ok({"uninstalled": str(install_id)})


# ---- Layout ---------------------------------------------------------------


class LayoutItem(BaseModel):
    install_id: UUID
    col: int = Field(ge=0)
    row: int = Field(ge=0)
    cw: int = Field(ge=1, le=4)
    ch: int = Field(ge=1, le=4)


class LayoutUpdateRequest(BaseModel):
    items: list[LayoutItem]


@installed_router.put(
    "/{family_id}/layout",
    response_model=ApiResponse[list[InstalledPluginRead]],
)
async def update_layout_endpoint(
    family_id: UUID,
    payload: LayoutUpdateRequest,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[InstalledPluginRead]]:
    items = [(i.install_id, i.col, i.row, i.cw, i.ch) for i in payload.items]
    updated = await plugin_service.update_layout(
        session,
        family_id=family_id,
        actor=current_user,
        items=items,
    )
    return ok([await to_installed_read(session, ip) for ip in updated])
