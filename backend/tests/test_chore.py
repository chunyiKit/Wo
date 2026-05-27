"""Chore plugin tests — CRUD, done toggle, assignee validation, manual remind,
and viewer-aware home preview."""

import uuid

from httpx import AsyncClient

# Seed users (see app/core/seed.py): 老陈 owns by default, 小林 / 小宝 join.
LAOCHEN = "019000a0-1100-7000-8000-000000000001"
XIAOLIN = {"X-User-Id": "019000a0-1100-7000-8000-000000000002"}
XIAOBAO = {"X-User-Id": "019000a0-1100-7000-8000-000000000003"}

CHORE_BASE = "/api/v1/families/{fid}/plugins/chore/chores"


def _unique_name() -> str:
    return f"家务测试-{uuid.uuid4().hex[:8]}"


async def _create_family(client: AsyncClient) -> str:
    response = await client.post("/api/v1/families", json={"name": _unique_name()})
    return response.json()["data"]["id"]


async def _family_with_xiaolin(client: AsyncClient) -> str:
    """老陈 owns a fresh family; 小林 joins as a member. Returns family_id."""
    fid = await _create_family(client)
    invite = await client.post(
        f"/api/v1/families/{fid}/invitations",
        json={"role": "member", "ttl_seconds": 3600, "channel": "link"},
    )
    code = invite.json()["data"]["code"]
    await client.post(f"/api/v1/invitations/{code}/accept", headers=XIAOLIN)
    return fid


async def test_create_and_list_chore(client: AsyncClient) -> None:
    fid = await _create_family(client)
    create = await client.post(
        CHORE_BASE.format(fid=fid),
        json={"title": "倒垃圾", "emoji": "🗑️", "note": "周三周六"},
    )
    assert create.status_code == 201, create.text
    created = create.json()["data"]
    assert created["title"] == "倒垃圾"
    assert created["done"] is False
    assert created["assigned_to"] is None

    listed = await client.get(CHORE_BASE.format(fid=fid))
    assert listed.status_code == 200
    data = listed.json()["data"]
    assert len(data) == 1
    assert data[0]["title"] == "倒垃圾"


async def test_assign_to_member_injects_name(client: AsyncClient) -> None:
    fid = await _family_with_xiaolin(client)
    create = await client.post(
        CHORE_BASE.format(fid=fid),
        json={"title": "洗碗", "assigned_to": XIAOLIN["X-User-Id"]},
    )
    assert create.status_code == 201, create.text
    created = create.json()["data"]
    assert created["assigned_to"] == XIAOLIN["X-User-Id"]
    # Assignee display info injected server-side from membership.
    assert created["assignee_name"]
    assert created["assignee_emoji"]


def _chore_assigns_for(notifs: list[dict], fid: str) -> list[dict]:
    return [n for n in notifs if n["type"] == "chore_assigned" and n["family_id"] == fid]


async def test_create_assigned_notifies_assignee(client: AsyncClient) -> None:
    fid = await _family_with_xiaolin(client)
    create = await client.post(
        CHORE_BASE.format(fid=fid),
        json={"title": "扔垃圾", "assigned_to": XIAOLIN["X-User-Id"]},
    )
    assert create.status_code == 201, create.text

    notifs = (await client.get("/api/v1/notifications", headers=XIAOLIN)).json()["data"]
    assigns = _chore_assigns_for(notifs, fid)
    assert len(assigns) == 1
    assert "扔垃圾" in assigns[0]["title"]
    assert assigns[0]["deeplink"] == f"wo://family/{fid}/plugins/chore"


async def test_assigning_to_self_does_not_notify(client: AsyncClient) -> None:
    # 老陈 (default actor) assigns a chore to themselves → no notification.
    fid = await _create_family(client)
    await client.post(
        CHORE_BASE.format(fid=fid),
        json={"title": "记账", "assigned_to": LAOCHEN},
    )
    notifs = (await client.get("/api/v1/notifications")).json()["data"]
    assert _chore_assigns_for(notifs, fid) == []


async def test_reassign_on_update_notifies_once(client: AsyncClient) -> None:
    fid = await _family_with_xiaolin(client)
    base = CHORE_BASE.format(fid=fid)
    cid = (await client.post(base, json={"title": "买菜"})).json()["data"]["id"]

    # First assignment via update → one notification.
    await client.put(
        f"{base}/{cid}",
        json={"title": "买菜", "emoji": "🛒", "assigned_to": XIAOLIN["X-User-Id"]},
    )
    # Editing other fields while keeping the same assignee → no extra ping.
    await client.put(
        f"{base}/{cid}",
        json={"title": "买菜和水果", "emoji": "🛒", "assigned_to": XIAOLIN["X-User-Id"]},
    )

    notifs = (await client.get("/api/v1/notifications", headers=XIAOLIN)).json()["data"]
    assert len(_chore_assigns_for(notifs, fid)) == 1


async def test_assign_to_non_member_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # 小宝 is not a member of this family.
    create = await client.post(
        CHORE_BASE.format(fid=fid),
        json={"title": "拖地", "assigned_to": XIAOBAO["X-User-Id"]},
    )
    assert create.status_code == 400
    assert create.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_blank_title_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    create = await client.post(CHORE_BASE.format(fid=fid), json={"title": "   "})
    assert create.status_code == 400


async def test_complete_and_reopen(client: AsyncClient) -> None:
    fid = await _create_family(client)
    cid = (await client.post(CHORE_BASE.format(fid=fid), json={"title": "晾衣服"})).json()["data"][
        "id"
    ]

    done = await client.post(f"{CHORE_BASE.format(fid=fid)}/{cid}/complete")
    assert done.status_code == 200
    assert done.json()["data"]["done"] is True
    assert done.json()["data"]["completed_at"] is not None

    reopened = await client.post(f"{CHORE_BASE.format(fid=fid)}/{cid}/reopen")
    assert reopened.status_code == 200
    assert reopened.json()["data"]["done"] is False
    assert reopened.json()["data"]["completed_at"] is None


async def test_list_filter_by_done(client: AsyncClient) -> None:
    fid = await _create_family(client)
    base = CHORE_BASE.format(fid=fid)
    keep = (await client.post(base, json={"title": "买菜"})).json()["data"]["id"]
    finish = (await client.post(base, json={"title": "修灯"})).json()["data"]["id"]
    await client.post(f"{base}/{finish}/complete")

    open_only = await client.get(base, params={"done": "false"})
    open_ids = {c["id"] for c in open_only.json()["data"]}
    assert keep in open_ids and finish not in open_ids

    done_only = await client.get(base, params={"done": "true"})
    done_ids = {c["id"] for c in done_only.json()["data"]}
    assert finish in done_ids and keep not in done_ids


async def test_update_chore(client: AsyncClient) -> None:
    fid = await _family_with_xiaolin(client)
    base = CHORE_BASE.format(fid=fid)
    cid = (await client.post(base, json={"title": "扫地"})).json()["data"]["id"]

    updated = await client.put(
        f"{base}/{cid}",
        json={
            "title": "扫地拖地",
            "emoji": "🧹",
            "note": "客厅+卧室",
            "assigned_to": XIAOLIN["X-User-Id"],
        },
    )
    assert updated.status_code == 200, updated.text
    data = updated.json()["data"]
    assert data["title"] == "扫地拖地"
    assert data["assigned_to"] == XIAOLIN["X-User-Id"]

    # Clearing the assignee with an explicit null.
    cleared = await client.put(
        f"{base}/{cid}",
        json={"title": "扫地拖地", "emoji": "🧹", "assigned_to": None},
    )
    assert cleared.json()["data"]["assigned_to"] is None


async def test_remind_creates_notification_for_assignee(
    client: AsyncClient,
) -> None:
    fid = await _family_with_xiaolin(client)
    base = CHORE_BASE.format(fid=fid)
    cid = (
        await client.post(
            base,
            json={"title": "遛狗", "assigned_to": XIAOLIN["X-User-Id"]},
        )
    ).json()["data"]["id"]

    remind = await client.post(f"{base}/{cid}/remind")
    assert remind.status_code == 200, remind.text
    assert remind.json()["data"]["reminded"] == XIAOLIN["X-User-Id"]

    # 小林 receives a chore_reminder notification with a chore deeplink.
    notifs = (await client.get("/api/v1/notifications", headers=XIAOLIN)).json()["data"]
    # Scope to this family — the test DB persists notifications across runs.
    reminders = [n for n in notifs if n["type"] == "chore_reminder" and n["family_id"] == fid]
    assert len(reminders) == 1
    assert "遛狗" in reminders[0]["title"]
    assert reminders[0]["deeplink"] == f"wo://family/{fid}/plugins/chore"


async def test_remind_unassigned_rejected(client: AsyncClient) -> None:
    fid = await _create_family(client)
    base = CHORE_BASE.format(fid=fid)
    cid = (await client.post(base, json={"title": "浇花"})).json()["data"]["id"]

    remind = await client.post(f"{base}/{cid}/remind")
    assert remind.status_code == 400
    assert remind.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_remind_done_rejected(client: AsyncClient) -> None:
    fid = await _family_with_xiaolin(client)
    base = CHORE_BASE.format(fid=fid)
    cid = (
        await client.post(base, json={"title": "收快递", "assigned_to": XIAOLIN["X-User-Id"]})
    ).json()["data"]["id"]
    await client.post(f"{base}/{cid}/complete")

    remind = await client.post(f"{base}/{cid}/remind")
    assert remind.status_code == 400


async def test_delete_chore(client: AsyncClient) -> None:
    fid = await _create_family(client)
    base = CHORE_BASE.format(fid=fid)
    cid = (await client.post(base, json={"title": "擦窗"})).json()["data"]["id"]

    deleted = await client.delete(f"{base}/{cid}")
    assert deleted.status_code == 200

    remaining = (await client.get(base)).json()["data"]
    assert all(c["id"] != cid for c in remaining)


async def test_create_recurring_flag(client: AsyncClient) -> None:
    fid = await _create_family(client)
    create = await client.post(
        CHORE_BASE.format(fid=fid),
        json={"title": "倒垃圾", "recurring": True},
    )
    assert create.status_code == 201, create.text
    assert create.json()["data"]["recurring"] is True

    # Defaults to one-off when the flag is omitted.
    other = await client.post(CHORE_BASE.format(fid=fid), json={"title": "修灯"})
    assert other.json()["data"]["recurring"] is False


async def test_update_toggles_recurring(client: AsyncClient) -> None:
    fid = await _create_family(client)
    base = CHORE_BASE.format(fid=fid)
    cid = (await client.post(base, json={"title": "拖地"})).json()["data"]["id"]

    updated = await client.put(
        f"{base}/{cid}",
        json={"title": "拖地", "emoji": "🧹", "recurring": True},
    )
    assert updated.json()["data"]["recurring"] is True


async def test_reset_recurring_reopens_only_done_recurring(client: AsyncClient) -> None:
    fid = await _family_with_xiaolin(client)
    base = CHORE_BASE.format(fid=fid)

    # A done recurring chore (assigned to 小林) — should be reopened, assignee kept.
    rec = (
        await client.post(
            base,
            json={"title": "洗碗", "recurring": True, "assigned_to": XIAOLIN["X-User-Id"]},
        )
    ).json()["data"]["id"]
    await client.post(f"{base}/{rec}/complete")

    # A done one-off chore — should stay done.
    once = (await client.post(base, json={"title": "修灯"})).json()["data"]["id"]
    await client.post(f"{base}/{once}/complete")

    # An open recurring chore — already待做, untouched.
    open_rec = (
        await client.post(base, json={"title": "扫地", "recurring": True})
    ).json()["data"]["id"]

    reset = await client.post(f"{base}/reset-recurring")
    assert reset.status_code == 200, reset.text
    assert reset.json()["data"]["reset"] == 1

    by_id = {c["id"]: c for c in (await client.get(base)).json()["data"]}
    # Done recurring → reopened, completed_at cleared, assignee preserved.
    assert by_id[rec]["done"] is False
    assert by_id[rec]["completed_at"] is None
    assert by_id[rec]["assigned_to"] == XIAOLIN["X-User-Id"]
    # One-off stays done; open recurring stays open.
    assert by_id[once]["done"] is True
    assert by_id[open_rec]["done"] is False


async def test_reset_recurring_no_match_returns_zero(client: AsyncClient) -> None:
    fid = await _create_family(client)
    base = CHORE_BASE.format(fid=fid)
    await client.post(base, json={"title": "买菜"})  # one-off, open

    reset = await client.post(f"{base}/reset-recurring")
    assert reset.status_code == 200
    assert reset.json()["data"]["reset"] == 0


async def test_non_member_forbidden(client: AsyncClient) -> None:
    fid = await _create_family(client)
    # 小宝 is not a member → family is hidden (404).
    response = await client.get(CHORE_BASE.format(fid=fid), headers=XIAOBAO)
    assert response.status_code == 404


async def test_preview_counts_my_open_chores(client: AsyncClient) -> None:
    from app.core.database import async_session_maker
    from app.models.plugin import InstalledPlugin
    from app.plugins.chore.service import preview_hook

    fid = await _family_with_xiaolin(client)
    base = CHORE_BASE.format(fid=fid)
    # Two chores for 小林, one already done; one for 老陈.
    await client.post(base, json={"title": "a", "assigned_to": XIAOLIN["X-User-Id"]})
    done_id = (
        await client.post(base, json={"title": "b", "assigned_to": XIAOLIN["X-User-Id"]})
    ).json()["data"]["id"]
    await client.post(f"{base}/{done_id}/complete")
    await client.post(base, json={"title": "c", "assigned_to": LAOCHEN})

    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="chore")
    async with async_session_maker() as session:
        mine = await preview_hook(session, ip, uuid.UUID(XIAOLIN["X-User-Id"]))
    # 小林 has exactly one open chore (the other is done).
    assert mine.badge == "1"
    assert "1" in mine.primary


async def test_preview_empty_when_nothing_open(client: AsyncClient) -> None:
    from app.core.database import async_session_maker
    from app.models.plugin import InstalledPlugin
    from app.plugins.chore.service import preview_hook

    fid = await _create_family(client)
    ip = InstalledPlugin(family_id=uuid.UUID(fid), plugin_id="chore")
    async with async_session_maker() as session:
        preview = await preview_hook(session, ip, uuid.UUID(LAOCHEN))
    assert preview.primary == "家务都做完啦"
