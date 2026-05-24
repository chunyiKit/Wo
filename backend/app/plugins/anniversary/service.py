"""Anniversary business logic — date math (solar + lunar) + preview hook."""

from datetime import date

from lunardate import LunarDate
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.plugin import InstalledPlugin
from app.plugins.anniversary.models import Anniversary, AnniversaryRead
from app.plugins.registry import PluginPreview

# lunardate covers solar dates 1900-02-19 .. ~2100; clamp our search to it.
_LUNAR_MAX_YEAR = 2099


def _next_solar_occurrence(target: date, today: date) -> date:
    """Next (this-year-or-later) occurrence of `target`'s month/day, Gregorian."""
    this_year = target.replace(year=today.year)
    if this_year < today:
        this_year = target.replace(year=today.year + 1)
    return this_year


def _lunar_to_solar_safe(
    year: int, month: int, day: int, is_leap: bool
) -> date | None:
    """Convert a lunar (year, month, day) to Gregorian, tolerating edge cases.

    A future lunar year may not have the original leap month, and a lunar
    month may be 29 days when the original fell on day 30 — fall back rather
    than raise so the countdown still resolves to a sensible nearby day.
    """
    for leap in (is_leap, False):
        for d in (day, day - 1):
            if d < 1:
                continue
            try:
                return LunarDate(year, month, d, leap).toSolarDate()
            except Exception:  # noqa: BLE001 — lib raises bare on out-of-range
                continue
    return None


def _next_lunar_occurrence(target: date, today: date) -> date | None:
    """Next Gregorian date whose lunar month/day matches `target`'s lunar date."""
    lunar = LunarDate.fromSolarDate(target.year, target.month, target.day)
    for year in range(today.year, min(today.year + 3, _LUNAR_MAX_YEAR + 1)):
        occ = _lunar_to_solar_safe(year, lunar.month, lunar.day, lunar.isLeapMonth)
        if occ is not None and occ >= today:
            return occ
    return None


def days_until(target: date, today: date | None = None, *, is_lunar: bool = False) -> int:
    """Days from `today` to the next occurrence of the anniversary.

    `is_lunar=True` recurs on the lunar anniversary of `target`; otherwise on the
    Gregorian month/day. Lunar conversion outside the library's range falls back
    to the Gregorian calculation so a result is always returned.
    """
    today = today or date.today()
    if is_lunar:
        occ = _next_lunar_occurrence(target, today)
        if occ is not None:
            return (occ - today).days
    return (_next_solar_occurrence(target, today) - today).days


def build_read(row: Anniversary, today: date | None = None) -> AnniversaryRead:
    """Serialize a row, injecting the computed `days_until` (immutable copy)."""
    read = AnniversaryRead.model_validate(row, from_attributes=True)
    return read.model_copy(
        update={"days_until": days_until(row.event_date, today, is_lunar=row.is_lunar)}
    )


def _countdown_preview(row: Anniversary, today: date) -> PluginPreview:
    delta = days_until(row.event_date, today, is_lunar=row.is_lunar)
    secondary = "就是今天 🎉" if delta == 0 else f"还有 {delta} 天"
    return PluginPreview(
        primary=row.name,
        secondary=secondary,
        color_token="anniv",
        emoji=row.emoji,
    )


async def preview_hook(session: AsyncSession, ip: InstalledPlugin) -> PluginPreview:
    """Render the home card for one installed anniversary widget.

    A card pinned via `config["anniversary_id"]` shows that specific date; an
    unpinned (overview) card shows the next-upcoming one. A pinned date that no
    longer exists silently falls back to the overview behaviour.
    """
    stmt = select(Anniversary).where(Anniversary.family_id == ip.family_id)
    rows = list((await session.execute(stmt)).scalars().all())

    if not rows:
        return PluginPreview(
            primary="还没有记录",
            secondary="点击添加第一个纪念日",
            color_token="anniv",
        )

    today = date.today()

    pinned_id = (ip.config or {}).get("anniversary_id")
    if pinned_id:
        pinned = next((r for r in rows if str(r.id) == str(pinned_id)), None)
        if pinned is not None:
            return _countdown_preview(pinned, today)
        # Pinned date was deleted → fall through to overview.

    next_one = min(rows, key=lambda r: days_until(r.event_date, today, is_lunar=r.is_lunar))
    return _countdown_preview(next_one, today)
