"""Plugin platform business logic — install, uninstall, layout updates.

Routes call into these functions. They handle permission checks (Admin+ for
mutations), layout validation (bounds + overlap), first-fit auto-placement,
and aggregate counter maintenance on the `plugins` table.
"""

from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.core.errors import AppError, ErrorCode
from app.core.permissions import require_admin, require_membership
from app.models.plugin import InstalledPlugin, Plugin
from app.models.user import User
from app.plugins.registry import registry

# Grid is fixed at 4 columns wide (see contract §5.6). Rows grow unbounded.
GRID_WIDTH = 4
_MAX_ROW_SCAN = 64  # safety cap for first-fit search


# ---- Layout primitives ----------------------------------------------------


def _validate_bounds(col: int, row: int, cw: int, ch: int) -> None:
    if not (1 <= cw <= GRID_WIDTH) or not (1 <= ch <= 4):
        raise AppError(
            ErrorCode.LAYOUT_CONFLICT,
            f"cw/ch 必须在 [1, {GRID_WIDTH}] / [1, 4]，得到 cw={cw}, ch={ch}",
            status_code=409,
        )
    if col < 0 or col + cw > GRID_WIDTH:
        raise AppError(
            ErrorCode.LAYOUT_CONFLICT,
            f"col+cw 超出右边界（col={col}, cw={cw}, 上限={GRID_WIDTH}）",
            status_code=409,
        )
    if row < 0:
        raise AppError(
            ErrorCode.LAYOUT_CONFLICT,
            f"row 必须 ≥ 0，得到 {row}",
            status_code=409,
        )


async def _occupied_cells(
    session: AsyncSession,
    family_id: UUID,
    exclude_install_id: UUID | None = None,
) -> set[tuple[int, int]]:
    """Set of all (col, row) cells currently occupied in a family's grid."""
    stmt = select(
        InstalledPlugin.id,
        InstalledPlugin.col,
        InstalledPlugin.row,
        InstalledPlugin.cw,
        InstalledPlugin.ch,
    ).where(InstalledPlugin.family_id == family_id)
    rows = (await session.execute(stmt)).all()
    cells: set[tuple[int, int]] = set()
    for ip_id, col, row, cw, ch in rows:
        if exclude_install_id is not None and ip_id == exclude_install_id:
            continue
        for dc in range(cw):
            for dr in range(ch):
                cells.add((col + dc, row + dr))
    return cells


def _first_fit(cells: set[tuple[int, int]], cw: int, ch: int) -> tuple[int, int]:
    """Find the topmost-leftmost (col, row) where a cw×ch tile fits."""
    for row in range(_MAX_ROW_SCAN):
        for col in range(0, GRID_WIDTH - cw + 1):
            if all((col + dc, row + dr) not in cells for dc in range(cw) for dr in range(ch)):
                return col, row
    raise AppError(
        ErrorCode.LAYOUT_CONFLICT,
        "首页放不下了，请先卸载一些插件",
        status_code=409,
    )


# ---- Install / uninstall --------------------------------------------------


async def install_plugin(
    session: AsyncSession,
    *,
    family_id: UUID,
    plugin_id: str,
    actor: User,
    layout: tuple[int, int, int, int] | None = None,
) -> InstalledPlugin:
    """Install a plugin into a family.

    If `layout` is None, the plugin is placed using first-fit with the
    manifest's default size. Otherwise the explicit (col, row, cw, ch) is
    validated for bounds and overlap.
    """
    membership = await require_membership(session, actor.id, family_id)
    require_admin(membership)

    manifest = registry.get_manifest(plugin_id)
    if manifest is None:
        raise AppError(
            ErrorCode.NOT_FOUND,
            f"未知插件：{plugin_id}",
            status_code=404,
            details={"plugin_id": plugin_id},
        )

    # Already installed?
    existing_stmt = select(InstalledPlugin).where(
        InstalledPlugin.family_id == family_id,
        InstalledPlugin.plugin_id == plugin_id,
    )
    if (await session.execute(existing_stmt)).scalar_one_or_none() is not None:
        raise AppError(
            ErrorCode.PLUGIN_ALREADY_INSTALLED,
            f"插件「{manifest.name}」已经安装",
            status_code=409,
            details={"plugin_id": plugin_id},
        )

    cells = await _occupied_cells(session, family_id)
    if layout is None:
        cw, ch = manifest.default_layout.cw, manifest.default_layout.ch
        col, row = _first_fit(cells, cw, ch)
    else:
        col, row, cw, ch = layout
        _validate_bounds(col, row, cw, ch)
        for dc in range(cw):
            for dr in range(ch):
                if (col + dc, row + dr) in cells:
                    raise AppError(
                        ErrorCode.LAYOUT_CONFLICT,
                        f"位置 ({col + dc},{row + dr}) 已被占用",
                        status_code=409,
                    )

    installed = InstalledPlugin(
        family_id=family_id,
        plugin_id=plugin_id,
        col=col,
        row=row,
        cw=cw,
        ch=ch,
        installed_by=actor.id,
    )
    session.add(installed)

    # Bump aggregate counter.
    db_plugin = await session.get(Plugin, plugin_id)
    if db_plugin is not None:
        db_plugin.install_count += 1
        session.add(db_plugin)

    await session.commit()
    await session.refresh(installed)
    return installed


async def uninstall_plugin(
    session: AsyncSession,
    *,
    family_id: UUID,
    install_id: UUID,
    actor: User,
) -> None:
    membership = await require_membership(session, actor.id, family_id)
    require_admin(membership)

    installed = await session.get(InstalledPlugin, install_id)
    if installed is None or installed.family_id != family_id:
        raise AppError(
            ErrorCode.NOT_FOUND,
            "安装记录不存在",
            status_code=404,
            details={"install_id": str(install_id)},
        )

    db_plugin = await session.get(Plugin, installed.plugin_id)
    if db_plugin is not None and db_plugin.install_count > 0:
        db_plugin.install_count -= 1
        session.add(db_plugin)

    await session.delete(installed)
    await session.commit()


# ---- Layout batch update --------------------------------------------------


async def update_layout(
    session: AsyncSession,
    *,
    family_id: UUID,
    actor: User,
    items: list[tuple[UUID, int, int, int, int]],
) -> list[InstalledPlugin]:
    """Replace the family's home layout atomically.

    The `items` list must cover *all* installed plugins in the family (and no
    extras). All cells are validated for bounds and pairwise non-overlap
    before any row is touched, so a bad request changes nothing.
    """
    membership = await require_membership(session, actor.id, family_id)
    require_admin(membership)

    stmt = select(InstalledPlugin).where(InstalledPlugin.family_id == family_id)
    installed = list((await session.execute(stmt)).scalars().all())
    by_id: dict[UUID, InstalledPlugin] = {ip.id: ip for ip in installed}

    incoming_ids = {item[0] for item in items}
    expected_ids = set(by_id.keys())
    if incoming_ids != expected_ids:
        raise AppError(
            ErrorCode.LAYOUT_CONFLICT,
            "items 必须覆盖且仅覆盖该家庭所有已安装插件",
            status_code=409,
            details={
                "missing": sorted(str(m) for m in expected_ids - incoming_ids),
                "extra": sorted(str(e) for e in incoming_ids - expected_ids),
            },
        )

    # Validate every cell first — no DB mutation until all checks pass.
    cells: set[tuple[int, int]] = set()
    for install_id, col, row, cw, ch in items:
        _validate_bounds(col, row, cw, ch)
        for dc in range(cw):
            for dr in range(ch):
                cell = (col + dc, row + dr)
                if cell in cells:
                    raise AppError(
                        ErrorCode.LAYOUT_CONFLICT,
                        f"位置 ({cell[0]},{cell[1]}) 被多次占用",
                        status_code=409,
                        details={"conflict_install_id": str(install_id)},
                    )
                cells.add(cell)

    # All clear — apply.
    for install_id, col, row, cw, ch in items:
        ip = by_id[install_id]
        ip.col, ip.row, ip.cw, ip.ch = col, row, cw, ch
        session.add(ip)

    await session.commit()
    for ip in installed:
        await session.refresh(ip)
    return installed
