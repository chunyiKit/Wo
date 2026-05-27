"""User notification preferences — master push switch + per-source toggles.

Stored as a JSON blob on `users.notification_prefs`:

    {"push_enabled": bool, "sources": {"<source_key>": bool, ...}}

Absent keys default to **enabled** (opt-out model), so existing users keep
getting everything until they explicitly turn something off.

These preferences gate **system push only** — whether a notification reaches the
phone's notification shade (i.e. whether a `PushOutbox` row is staged). The
in-app message center always records the notification regardless.

A notification's *source key* groups it for the toggles:
- platform / family events (member_joined, role_changed, ...) → ``"family"``
- plugin notifications → the plugin id (``anniversary`` / ``accounting`` / ``chore``)

The plugin source key equals the segment of the notification ``type`` before the
first underscore, which by construction matches the plugin id (e.g.
``accounting_month_end`` → ``accounting``). Platform types are listed explicitly.
"""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.plugin import InstalledPlugin
from app.models.user import User
from app.plugins.registry import registry

FAMILY_SOURCE = "family"
FAMILY_SOURCE_LABEL = "家庭与成员动态"
FAMILY_SOURCE_EMOJI = "👨‍👩‍👧"

# Platform notification types (not owned by any plugin) — grouped under "family".
PLATFORM_TYPES: frozenset[str] = frozenset(
    {
        "member_joined",
        "member_left",
        "role_changed",
        "ownership_received",
        "ownership_transferred",
    }
)


def source_key_for_type(notification_type: str) -> str:
    """Map a notification ``type`` to the toggle key it belongs to."""
    if notification_type in PLATFORM_TYPES:
        return FAMILY_SOURCE
    return notification_type.split("_", 1)[0]


def push_allowed(prefs: dict | None, notification_type: str) -> bool:
    """Whether the user's prefs permit a *system push* for this notification.

    Master switch off → never push. Otherwise the per-source toggle decides,
    defaulting to enabled when unset.
    """
    prefs = prefs or {}
    if not prefs.get("push_enabled", True):
        return False
    sources = prefs.get("sources") or {}
    return bool(sources.get(source_key_for_type(notification_type), True))


def merge_prefs(
    current: dict | None,
    *,
    push_enabled: bool | None,
    sources: dict[str, bool] | None,
) -> dict:
    """Return a new prefs dict with the given partial updates applied.

    Immutable: never mutates ``current`` in place.
    """
    base = dict(current or {})
    if push_enabled is not None:
        base["push_enabled"] = push_enabled
    if sources:
        merged_sources = dict(base.get("sources") or {})
        merged_sources.update(sources)
        base["sources"] = merged_sources
    return base


async def list_sources(session: AsyncSession, user: User) -> list[tuple[str, str, str]]:
    """The toggleable notification sources for this user, as (key, label, emoji).

    Always includes the platform "family" source, followed by every plugin
    installed in the user's current family that declares notification types
    (deduped by plugin id, in install order).
    """
    sources: list[tuple[str, str, str]] = [
        (FAMILY_SOURCE, FAMILY_SOURCE_LABEL, FAMILY_SOURCE_EMOJI),
    ]
    if user.current_family_id is None:
        return sources

    stmt = (
        select(InstalledPlugin.plugin_id)
        .where(InstalledPlugin.family_id == user.current_family_id)
        .order_by(InstalledPlugin.installed_at)
    )
    plugin_ids = (await session.execute(stmt)).scalars().all()

    seen: set[str] = set()
    for pid in plugin_ids:
        if pid in seen:
            continue
        seen.add(pid)
        manifest = registry.get_manifest(pid)
        if manifest is None or not manifest.notification_types:
            continue
        sources.append((manifest.id, manifest.name, manifest.emoji))
    return sources
