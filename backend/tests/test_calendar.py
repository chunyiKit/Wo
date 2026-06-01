"""Calendar (家历) plugin tests — CRUD, undated todos, recurrence completion,
assignee injection, due reminders, and the home preview."""

import uuid
from datetime import date, timedelta

import pytest
from httpx import AsyncClient

# Seed users (see app/core/seed.py): 老陈 owns by default, 小林 joins.
LAOCHEN = "019000a0-1100-7000-8000-000000000001"
XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}

BASE = "/api/v1/families/{fid}/plugins/calendar/items"


async def _create_family(client: AsyncClient) -> str:
    resp = await client.post(
        "/api/v1/families", json={"name": f"测试-{uuid.uuid4().hex[:6]}"}
    )
    return resp.json()["data"]["id"]


async def _family_with_xiaolin(client: AsyncClient) -> str:
    fid = await _create_family(client)
    invite = await client.post(
        f"/api/v1/families/{fid}/invitations",
        json={"role": "member", "ttl_seconds": 3600, "channel": "link"},
    )
    code = invite.json()["data"]["code"]
    await client.post(f"/api/v1/invitations/{code}/accept", headers=XIAOLIN)
    return fid


# ---- CRUD ------------------------------------------------------------------


async def test_create_dated_event(client: AsyncClient) -> None:
    fid = await _create_family(client)
    day = (date.today() + timedelta(days=3)).isoformat()
    resp = await client.post(
        BASE.format(fid=fid),
        json={"title": "看牙医", "event_date": day, "all_day": False, "start_minute": 600},
    )
    assert resp.status_code == 201, resp.text
    data = resp.json()["data"]
    assert data["title"] == "看牙医"
    assert data["event_date"] == day
    assert data["all_day"] is False
    assert data["start_minute"] == 600
    assert data["next_date"] == day
    assert data["days_until"] == 3
    assert data["done"] is False


async def test_create_undated_todo_normalizes(client: AsyncClient) -> None:
    """An undated todo can't carry a time / recurrence / reminder — those are
    stripped server-side even if the client sends them."""
    fid = await _create_family(client)
    resp = await client.post(
        BASE.format(fid=fid),
        json={
            "title": "想想周末去哪玩",
            "repeat": "weekly",
            "start_minute": 540,
            "notify_enabled": True,
        },
    )
    assert resp.status_code == 201, resp.text
    data = resp.json()["data"]
    assert data["event_date"] is None
    assert data["repeat"] == "none"
    assert data["start_minute"] is None
    assert data["notify_enabled"] is False
    assert data["next_date"] is None
    assert data["days_until"] is None


async def test_empty_title_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    resp = await client.post(BASE.format(fid=fid), json={"title": "   "})
    assert resp.status_code == 400


async def test_all_day_clears_start_minute(client: AsyncClient) -> None:
    fid = await _create_family(client)
    day = date.today().isoformat()
    resp = await client.post(
        BASE.format(fid=fid),
        json={"title": "全天活动", "event_date": day, "all_day": True, "start_minute": 600},
    )
    assert resp.json()["data"]["start_minute"] is None


async def test_delete(client: AsyncClient) -> None:
    fid = await _create_family(client)
    iid = (
        await client.post(BASE.format(fid=fid), json={"title": "删除我"})
    ).json()["data"]["id"]
    resp = await client.delete(f"{BASE.format(fid=fid)}/{iid}")
    assert resp.status_code == 200
    assert (await client.get(BASE.format(fid=fid))).json()["data"] == []


# ---- assignee --------------------------------------------------------------


async def test_assign_member_injects_avatar_info(client: AsyncClient) -> None:
    fid = await _family_with_xiaolin(client)
    resp = await client.post(
        BASE.format(fid=fid),
        json={"title": "接孩子", "assigned_to": XIAOLIN["X-User-Id"]},
    )
    data = resp.json()["data"]
    assert data["assigned_to"] == XIAOLIN["X-User-Id"]
    assert data["assignee_name"]  # injected from membership
    assert data["assignee_emoji"]


async def test_assign_to_outsider_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    resp = await client.post(
        BASE.format(fid=fid),
        json={"title": "x", "assigned_to": str(uuid.uuid4())},
    )
    assert resp.status_code == 400


# ---- completion / recurrence ----------------------------------------------


async def test_complete_single_item_marks_done(client: AsyncClient) -> None:
    fid = await _create_family(client)
    iid = (
        await client.post(
            BASE.format(fid=fid),
            json={"title": "交电费", "event_date": date.today().isoformat()},
        )
    ).json()["data"]["id"]
    resp = await client.post(f"{BASE.format(fid=fid)}/{iid}/complete")
    data = resp.json()["data"]
    assert data["done"] is True
    assert data["completed_at"] is not None


async def test_complete_recurring_rolls_date_forward(client: AsyncClient) -> None:
    """Completing a weekly item advances its date by a week and keeps it open."""
    fid = await _create_family(client)
    today = date.today()
    iid = (
        await client.post(
            BASE.format(fid=fid),
            json={"title": "每周倒垃圾", "event_date": today.isoformat(), "repeat": "weekly"},
        )
    ).json()["data"]["id"]
    resp = await client.post(f"{BASE.format(fid=fid)}/{iid}/complete")
    data = resp.json()["data"]
    assert data["done"] is False
    assert data["event_date"] == (today + timedelta(days=7)).isoformat()


async def test_reopen(client: AsyncClient) -> None:
    fid = await _create_family(client)
    iid = (
        await client.post(BASE.format(fid=fid), json={"title": "一次性待办"})
    ).json()["data"]["id"]
    await client.post(f"{BASE.format(fid=fid)}/{iid}/complete")
    resp = await client.post(f"{BASE.format(fid=fid)}/{iid}/reopen")
    assert resp.json()["data"]["done"] is False


async def test_list_filter_and_order(client: AsyncClient) -> None:
    fid = await _create_family(client)
    today = date.today()
    await client.post(
        BASE.format(fid=fid),
        json={"title": "后天", "event_date": (today + timedelta(days=2)).isoformat()},
    )
    await client.post(
        BASE.format(fid=fid),
        json={"title": "明天", "event_date": (today + timedelta(days=1)).isoformat()},
    )
    await client.post(BASE.format(fid=fid), json={"title": "无日期待办"})

    listed = (await client.get(BASE.format(fid=fid))).json()["data"]
    # Soonest dated first, undated last.
    assert [i["title"] for i in listed] == ["明天", "后天", "无日期待办"]

    open_only = await client.get(BASE.format(fid=fid), params={"done": "false"})
    assert len(open_only.json()["data"]) == 3


# ---- reminders -------------------------------------------------------------


async def test_due_reminder_fires_once(client: AsyncClient) -> None:
    from app.core.database import async_session_maker
    from app.plugins.calendar.reminders import check_due_calendar_items

    fid = await _create_family(client)
    today = date.today()
    await client.post(
        BASE.format(fid=fid),
        json={
            "title": "今天到期",
            "event_date": today.isoformat(),
            "notify_enabled": True,
            "notify_days_before": 0,
        },
    )
    async with async_session_maker() as session:
        first = await check_due_calendar_items(session, today=today)
        second = await check_due_calendar_items(session, today=today)
    assert first == 1
    assert second == 0  # idempotent per occurrence


async def test_reminder_skips_outside_window(client: AsyncClient) -> None:
    from app.core.database import async_session_maker
    from app.plugins.calendar.reminders import check_due_calendar_items

    fid = await _create_family(client)
    today = date.today()
    await client.post(
        BASE.format(fid=fid),
        json={
            "title": "还很远",
            "event_date": (today + timedelta(days=10)).isoformat(),
            "notify_enabled": True,
            "notify_days_before": 1,
        },
    )
    async with async_session_maker() as session:
        assert await check_due_calendar_items(session, today=today) == 0


# ---- preview ---------------------------------------------------------------


@pytest.fixture
def _preview_imports():
    from app.core.database import async_session_maker
    from app.models.plugin import InstalledPlugin
    from app.plugins.calendar.service import preview_hook

    return async_session_maker, InstalledPlugin, preview_hook


async def test_preview_empty(client: AsyncClient, _preview_imports) -> None:
    async_session_maker, InstalledPlugin, preview_hook = _preview_imports
    fid = await _create_family(client)
    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="calendar")
    async with async_session_maker() as session:
        preview = await preview_hook(session, ip, uuid.UUID(LAOCHEN))
    assert preview.primary == "还没有安排"


async def test_preview_upcoming(client: AsyncClient, _preview_imports) -> None:
    async_session_maker, InstalledPlugin, preview_hook = _preview_imports
    fid = await _create_family(client)
    await client.post(
        BASE.format(fid=fid),
        json={"title": "今天的事", "event_date": date.today().isoformat()},
    )
    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="calendar")
    async with async_session_maker() as session:
        preview = await preview_hook(session, ip, uuid.UUID(LAOCHEN))
    assert preview.primary == "今天的事"
    assert preview.secondary == "就在今天"


async def test_preview_todos_only(client: AsyncClient, _preview_imports) -> None:
    async_session_maker, InstalledPlugin, preview_hook = _preview_imports
    fid = await _create_family(client)
    await client.post(BASE.format(fid=fid), json={"title": "待办一"})
    await client.post(BASE.format(fid=fid), json={"title": "待办二"})
    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="calendar")
    async with async_session_maker() as session:
        preview = await preview_hook(session, ip, uuid.UUID(LAOCHEN))
    assert preview.primary == "2 件待办"
