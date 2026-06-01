"""Calendar (家历) business logic — recurrence math, read builder, preview hook."""

from calendar import monthrange
from datetime import date, timedelta
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from app.models.plugin import InstalledPlugin
from app.plugins.calendar.models import CalendarItem, CalendarItemRead
from app.plugins.registry import PluginPreview
from app.services.membership import MemberInfo, author_avatar_url


def _clamp_day(year: int, month: int, day: int) -> date:
    """A valid date for (year, month, day), clamping day to the month's length
    (so a monthly-on-the-31st item lands on the 30th/28th in shorter months)."""
    last = monthrange(year, month)[1]
    return date(year, month, min(day, last))


def _add_months(anchor: date, months: int) -> date:
    total = (anchor.year * 12 + (anchor.month - 1)) + months
    year, month = divmod(total, 12)
    return _clamp_day(year, month + 1, anchor.day)


def next_occurrence(anchor: date, repeat: str, today: date) -> date:
    """The next occurrence on/after `today` for a recurring item.

    Non-recurring items always resolve to `anchor` (even if it's in the past, so
    overdue single items still surface). Recurring items roll forward from
    `anchor` to the first occurrence that is `>= today`.
    """
    if repeat == "none" or anchor >= today:
        return anchor
    if repeat == "daily":
        return today
    if repeat == "weekly":
        delta = (anchor.weekday() - today.weekday()) % 7
        return today + timedelta(days=delta)
    if repeat == "monthly":
        # Walk forward month by month from today until we hit anchor's day-of-month.
        candidate = _clamp_day(today.year, today.month, anchor.day)
        if candidate < today:
            candidate = _add_months(candidate.replace(day=anchor.day), 1)
        return candidate
    return anchor


def advance_occurrence(anchor: date, repeat: str, today: date) -> date:
    """The next occurrence strictly after `today` — used when completing a
    recurring item so it rolls to the future (not back onto today)."""
    nxt = next_occurrence(anchor, repeat, today)
    if nxt > today:
        return nxt
    # nxt == today (or anchor==today): step one full period forward.
    if repeat == "daily":
        return today + timedelta(days=1)
    if repeat == "weekly":
        return today + timedelta(days=7)
    if repeat == "monthly":
        return _add_months(anchor, 1) if anchor.day == today.day else _clamp_day(
            *_next_month_ym(today), anchor.day
        )
    return today


def _next_month_ym(d: date) -> tuple[int, int]:
    return (d.year + 1, 1) if d.month == 12 else (d.year, d.month + 1)


def build_read(
    row: CalendarItem, members: dict[UUID, MemberInfo], today: date
) -> CalendarItemRead:
    """Serialize a row, injecting next_date / days_until + assignee display."""
    read = CalendarItemRead.model_validate(row, from_attributes=True)
    info = members.get(row.assigned_to) if row.assigned_to is not None else None

    next_date: date | None = None
    days_until: int | None = None
    if row.event_date is not None:
        next_date = next_occurrence(row.event_date, row.repeat, today)
        days_until = (next_date - today).days

    return read.model_copy(
        update={
            "next_date": next_date,
            "days_until": days_until,
            "assignee_name": info.name if info else None,
            "assignee_emoji": info.emoji if info else None,
            "assignee_avatar_url": author_avatar_url(
                row.family_id, row.assigned_to, info
            ),
        }
    )


def _sort_key(row: CalendarItem, today: date) -> tuple[int, date, int]:
    """Order: undated todos last; dated items by next occurrence, then time."""
    if row.event_date is None:
        return (1, date.max, 0)
    nxt = next_occurrence(row.event_date, row.repeat, today)
    return (0, nxt, row.start_minute if row.start_minute is not None else -1)


async def preview_hook(
    session: AsyncSession, ip: InstalledPlugin, _viewer_id: UUID | None = None
) -> PluginPreview:
    """Home card: the next upcoming item (soonest non-done dated item), else a
    count of open undated todos, else an all-clear."""
    stmt = select(CalendarItem).where(
        CalendarItem.family_id == ip.family_id,
        CalendarItem.done.is_(False),
    )
    rows = list((await session.execute(stmt)).scalars().all())
    if not rows:
        return PluginPreview(
            primary="还没有安排",
            secondary="点击添加第一件事",
            color_token="calendar",
            emoji="📅",
        )

    today = date.today()
    dated = [r for r in rows if r.event_date is not None]
    if dated:
        nxt = min(dated, key=lambda r: next_occurrence(r.event_date, r.repeat, today))  # type: ignore[arg-type]
        occ = next_occurrence(nxt.event_date, nxt.repeat, today)  # type: ignore[arg-type]
        delta = (occ - today).days
        if delta < 0:
            secondary = f"已过期 {-delta} 天"
            tone = "danger"
        elif delta == 0:
            secondary = "就在今天"
            tone = "warning"
        elif delta == 1:
            secondary = "明天"
            tone = None
        else:
            secondary = f"还有 {delta} 天"
            tone = None
        return PluginPreview(
            primary=nxt.title,
            secondary=secondary,
            color_token="calendar",
            secondary_tone=tone,
            emoji=nxt.emoji,
        )

    todos = len(rows)
    return PluginPreview(
        primary=f"{todos} 件待办",
        secondary="还没排到具体哪天",
        color_token="calendar",
        emoji="📝",
    )


__all__ = ["build_read", "next_occurrence", "advance_occurrence", "preview_hook"]
