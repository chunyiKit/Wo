"""Idempotent seed-data bootstrap.

`ensure_seed_users` inserts three fixed dev users so we can act as different
identities via the `X-User-Id` header (remove once P5 wires real auth).

`ensure_plugins` syncs the in-code plugin registry → the `plugins` aggregate
table. It's safe to call every startup: new plugins are inserted, existing
ones get their `current_version` refreshed, install_count/rating untouched.

Both run inside the per-worker lifespan, so with `uvicorn --workers N` they
fire concurrently against the same DB. They use Postgres `ON CONFLICT` so a
fresh-DB boot where two workers race on the same primary key can't crash —
the loser silently no-ops instead of raising a UniqueViolation.
"""

from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy.dialects.postgresql import insert as pg_insert

from app.core.database import async_session_maker
from app.core.ids import SEED_USER_ID, SEED_USER_ID_2, SEED_USER_ID_3
from app.models.plugin import Plugin
from app.models.user import User
from app.plugins.registry import registry

# Phones let testers log in as a seed user via POST /auth/login (the migration
# backfills the same numbers onto already-deployed rows).
_SEED_USERS: tuple[tuple[UUID, dict[str, object]], ...] = (
    (
        SEED_USER_ID,
        {
            "username": "laochen",
            "display_name": "老陈",
            "avatar_emoji": "👨",
            "level": 3,
            "phone": "13800000001",
        },
    ),
    (
        SEED_USER_ID_2,
        {
            "username": "xiaolin",
            "display_name": "小林",
            "avatar_emoji": "👩",
            "level": 2,
            "phone": "13800000002",
        },
    ),
    (
        SEED_USER_ID_3,
        {
            "username": "xiaobao",
            "display_name": "小宝",
            "avatar_emoji": "🧒",
            "level": 1,
            "phone": "13800000003",
        },
    ),
)


async def ensure_seed_users() -> None:
    # created_at lives on a sa_column whose default is only applied during Python
    # `User(...)` construction, not at the DB level — so set it explicitly here
    # since the Core insert below bypasses ORM object construction.
    now = datetime.now(UTC)
    rows = [{"id": user_id, "created_at": now, **fields} for user_id, fields in _SEED_USERS]
    stmt = pg_insert(User).values(rows).on_conflict_do_nothing(index_elements=["id"])
    async with async_session_maker() as session:
        await session.execute(stmt)
        await session.commit()


async def ensure_plugins() -> None:
    """Reflect the in-code plugin registry into the `plugins` aggregate table."""
    now = datetime.now(UTC)
    async with async_session_maker() as session:
        for manifest in registry.list_manifests():
            stmt = (
                pg_insert(Plugin)
                .values(
                    id=manifest.id,
                    current_version=manifest.version,
                    published_at=now,
                )
                # Keep aggregates (install_count, rating, published_at); only
                # refresh version. DO UPDATE (not DO NOTHING) so a version bump
                # in code propagates on the next boot.
                .on_conflict_do_update(
                    index_elements=["id"],
                    set_={"current_version": manifest.version},
                )
            )
            await session.execute(stmt)
        await session.commit()
