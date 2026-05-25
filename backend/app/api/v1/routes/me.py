"""Current-user endpoints — `/me`, `/me/families`, `/me/bootstrap`.

`/me/bootstrap` is the first-frame aggregator (contract §6.1): one request
returns user + current_family + families + installed_plugins + unread_count,
so the Flutter splash screen doesn't fan out to 4 endpoints in parallel.
"""

from datetime import UTC, datetime

from fastapi import APIRouter
from pydantic import BaseModel
from sqlmodel import select

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep
from app.core.response import ApiResponse, ok
from app.models.family import FamilyRead
from app.models.plugin import InstalledPlugin
from app.models.user import UserRead, UserUpdate
from app.plugins.views import InstalledPluginRead, to_installed_read
from app.services import family as family_service
from app.services import notification as notification_service

router = APIRouter(tags=["me"])


class StatsRead(BaseModel):
    families_joined: int
    plugins_used: int = 0  # P3 will populate this
    days_active: int


class MeResponse(BaseModel):
    user: UserRead
    current_family: FamilyRead | None
    stats: StatsRead


class BootstrapResponse(BaseModel):
    """Everything the splash screen needs in a single round-trip."""

    user: UserRead
    current_family: FamilyRead | None
    families: list[FamilyRead]
    installed_plugins: list[InstalledPluginRead]
    unread_count: int


def _days_since(then: datetime) -> int:
    return max(0, (datetime.now(UTC) - then).days)


@router.get("/me", response_model=ApiResponse[MeResponse])
async def me(
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[MeResponse]:
    families = await family_service.list_user_families(session, current_user)

    current: FamilyRead | None = None
    if current_user.current_family_id is not None:
        for f, m, cnt in families:
            if f.id == current_user.current_family_id:
                current = FamilyRead.from_components(f, m, cnt)
                break

    stats = StatsRead(
        families_joined=len(families),
        days_active=_days_since(current_user.created_at),
    )
    return ok(
        MeResponse(
            user=UserRead.model_validate(current_user, from_attributes=True),
            current_family=current,
            stats=stats,
        )
    )


@router.patch("/me", response_model=ApiResponse[UserRead])
async def update_me(
    payload: UserUpdate,
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[UserRead]:
    """更新当前用户资料（目前支持昵称 display_name）。仅更新提供的字段。"""
    for key, value in payload.model_dump(exclude_unset=True).items():
        setattr(current_user, key, value)
    session.add(current_user)
    await session.commit()
    await session.refresh(current_user)
    return ok(UserRead.model_validate(current_user, from_attributes=True))


@router.get("/me/families", response_model=ApiResponse[list[FamilyRead]])
async def my_families(
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[list[FamilyRead]]:
    families = await family_service.list_user_families(session, current_user)
    return ok([FamilyRead.from_components(f, m, cnt) for f, m, cnt in families])


@router.get("/me/bootstrap", response_model=ApiResponse[BootstrapResponse])
async def bootstrap(
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[BootstrapResponse]:
    """First-frame aggregator — see contract §6.1."""
    families = await family_service.list_user_families(session, current_user)

    current_family: FamilyRead | None = None
    installed_plugins: list[InstalledPluginRead] = []
    if current_user.current_family_id is not None:
        for f, m, cnt in families:
            if f.id == current_user.current_family_id:
                current_family = FamilyRead.from_components(f, m, cnt)
                stmt = (
                    select(InstalledPlugin)
                    .where(InstalledPlugin.family_id == f.id)
                    .order_by(InstalledPlugin.row, InstalledPlugin.col)
                )
                rows = (await session.execute(stmt)).scalars().all()
                installed_plugins = [await to_installed_read(session, r) for r in rows]
                break

    unread = await notification_service.count_unread(session, current_user.id)

    return ok(
        BootstrapResponse(
            user=UserRead.model_validate(current_user, from_attributes=True),
            current_family=current_family,
            families=[FamilyRead.from_components(f, m, cnt) for f, m, cnt in families],
            installed_plugins=installed_plugins,
            unread_count=unread,
        )
    )
