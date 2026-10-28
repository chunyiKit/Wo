"""账号注销测试。

清空账号身份、凭据与个人头像；家庭历史内容和附件保留，作者匿名展示。
原有私密范围不变，其他成员的内容与身份不受影响。
"""

import uuid

import pytest
from httpx import AsyncClient
from PIL import Image
from sqlalchemy import select

from app.core.database import async_session_maker
from app.core.password import hash_password
from app.core.storage import storage
from app.models.family import Family
from app.models.membership import Membership
from app.models.user import User
from app.plugins.chat.models import ChatMessage
from app.plugins.memory.models import Memory, MemoryMedia
from app.plugins.registry import registry
from app.services.membership import ANONYMOUS_MEMBER
from app.services.session import issue_session

DELETE_URL = "/api/v1/me/delete-account"
PASSWORD = "synthetic-test-password"
MEM_BASE = "/api/v1/families/{fid}/plugins/memory/memories"


def _png() -> bytes:
    from io import BytesIO

    img = Image.new("RGB", (60, 40), color=(200, 80, 40))
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


async def _new_user() -> str:
    """建一个带密码的隔离用户，返回 id（测试用 X-User-Id 头扮演他）。"""
    async with async_session_maker() as session:
        user = User(
            username=f"del-{uuid.uuid4().hex[:16]}",
            display_name="待注销",
            phone="139" + str(uuid.uuid4().int)[:8],
            password_hash=hash_password(PASSWORD),
        )
        session.add(user)
        await session.commit()
        return str(user.id)


def _as(user_id: str) -> dict:
    return {"X-User-Id": user_id}


def _u(value: str):
    return uuid.UUID(value)


async def _create_family(client: AsyncClient, owner: str) -> str:
    resp = await client.post(
        "/api/v1/families", json={"name": f"家-{uuid.uuid4().hex[:6]}"}, headers=_as(owner)
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]["id"]


async def _join(client: AsyncClient, fid: str, inviter: str, joiner: str) -> None:
    invite = await client.post(
        f"/api/v1/families/{fid}/invitations",
        json={"role": "member", "ttl_seconds": 3600, "channel": "link"},
        headers=_as(inviter),
    )
    assert invite.status_code == 201, invite.text
    code = invite.json()["data"]["code"]
    accept = await client.post(f"/api/v1/invitations/{code}/accept", headers=_as(joiner))
    assert accept.status_code == 200, accept.text


async def _memory_with_photo(
    client: AsyncClient, fid: str, author: str, title: str, **extra
) -> str:
    """发一条带照片的回忆，返回 memory_id。"""
    created = await client.post(
        MEM_BASE.format(fid=fid), json={"title": title, **extra}, headers=_as(author)
    )
    assert created.status_code == 201, created.text
    mid = created.json()["data"]["id"]

    upload = await client.post(
        f"{MEM_BASE.format(fid=fid)}/{mid}/media",
        files={"file": ("p.png", _png(), "image/png")},
        headers=_as(author),
    )
    assert upload.status_code == 201, upload.text
    return mid


async def test_delete_account_requires_correct_password(client: AsyncClient) -> None:
    """密码不对就不能注销 —— 否则拿到手机的人能把整个账号清掉。"""
    uid = await _new_user()

    wrong = await client.post(DELETE_URL, json={"password": "wrong-password"}, headers=_as(uid))
    assert wrong.status_code == 401
    assert wrong.json()["error"]["code"] == "UNAUTHORIZED"

    # 账号必须还在：错误的尝试不能有任何副作用
    me = await client.get("/api/v1/me", headers=_as(uid))
    assert me.status_code == 200
    async with async_session_maker() as session:
        row = (await session.execute(select(User).where(User.id == _u(uid)))).scalar_one()
        assert row.deleted_at is None
        assert row.password_hash is not None


async def test_delete_account_preserves_memories_media_and_comments(
    client: AsyncClient,
) -> None:
    """注销只改变作者展示，自己和别人的回忆、附件、留言均完整保留。"""
    owner = await _new_user()
    other = await _new_user()
    fid = await _create_family(client, owner)
    await _join(client, fid, owner, other)

    mine = await _memory_with_photo(client, fid, owner, "我的回忆")
    theirs = await _memory_with_photo(client, fid, other, "别人的回忆")
    base = MEM_BASE.format(fid=fid)
    for mid, author, body in ((mine, other, "家人给我的留言"), (theirs, owner, "我的留言")):
        posted = await client.post(
            f"{base}/{mid}/comments", json={"body": body}, headers=_as(author)
        )
        assert posted.status_code == 201, posted.text
    # 本人挂在其他成员回忆下的附件也必须保留。
    upload = await client.post(
        f"{base}/{theirs}/media",
        files={"file": ("mine.png", _png(), "image/png")},
        headers=_as(owner),
    )
    assert upload.status_code == 201, upload.text
    before = {
        mid: (await client.get(f"{base}/{mid}", headers=_as(other))).json()["data"]
        for mid in (mine, theirs)
    }

    resp = await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(owner))
    assert resp.status_code == 200, resp.text

    async with async_session_maker() as session:
        remaining = (
            (await session.execute(select(Memory.id).where(Memory.family_id == _u(fid))))
            .scalars()
            .all()
        )
        assert {str(m) for m in remaining} == {mine, theirs}
        media = (
            (
                await session.execute(
                    select(MemoryMedia.storage_key).where(MemoryMedia.family_id == _u(fid))
                )
            )
            .scalars()
            .all()
        )
        assert len(media) == 3
        assert all([await storage.exists(key) for key in media])
    for mid in (mine, theirs):
        after = (await client.get(f"{base}/{mid}", headers=_as(other))).json()["data"]
        for field in ("title", "body", "visibility", "event_date", "media", "comment_count"):
            assert after[field] == before[mid][field]
        assert [c["body"] for c in after["comments"]] == [
            c["body"] for c in before[mid]["comments"]
        ]
        if mid == mine:
            assert after["author_name"] == ANONYMOUS_MEMBER.name
            assert after["author_emoji"] == ANONYMOUS_MEMBER.emoji
            assert after["author_avatar_url"] is None
            assert after["comments"][0]["author_name"] == before[mid]["comments"][0]["author_name"]
        else:
            assert after["author_name"] == before[mid]["author_name"]
            assert after["comments"][0]["author_name"] == ANONYMOUS_MEMBER.name
            assert after["comments"][0]["author_avatar_url"] is None


async def test_delete_account_removes_avatar_but_preserves_content_files(
    client: AsyncClient,
) -> None:
    """只删除个人头像；家庭媒体保持可读取。"""
    uid = await _new_user()
    other = await _new_user()
    fid = await _create_family(client, uid)
    await _join(client, fid, uid, other)
    await _memory_with_photo(client, fid, uid, "带照片的")
    avatar = await client.post(
        "/api/v1/me/avatar",
        headers=_as(uid),
        files={"file": ("avatar.png", _png(), "image/png")},
    )
    assert avatar.status_code == 200, avatar.text

    async with async_session_maker() as session:
        keys = (
            (
                await session.execute(
                    select(MemoryMedia.storage_key).where(MemoryMedia.family_id == _u(fid))
                )
            )
            .scalars()
            .all()
        )
        avatar_key = (await session.get(User, _u(uid))).avatar_storage_key
    assert keys, "前置条件：应该有一张照片"
    assert all([await storage.exists(k) for k in keys])

    resp = await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(uid))
    assert resp.status_code == 200, resp.text
    assert resp.json()["data"]["storage_objects_deleted"] == 1
    assert not await storage.exists(avatar_key)

    for key in keys:
        assert await storage.exists(key), f"家庭附件 {key} 必须保留"


async def test_delete_account_keeps_private_memories_private(client: AsyncClient) -> None:
    owner, other = await _new_user(), await _new_user()
    fid = await _create_family(client, owner)
    await _join(client, fid, owner, other)
    mid = await _memory_with_photo(client, fid, owner, "私密回忆", visibility="private")
    base = MEM_BASE.format(fid=fid)
    detail = (await client.get(f"{base}/{mid}", headers=_as(owner))).json()["data"]
    resp = await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(owner))
    assert resp.status_code == 200, resp.text
    assert (await client.get(f"{base}/{mid}", headers=_as(other))).status_code == 404
    assert (await client.get(detail["media"][0]["url"], headers=_as(other))).status_code == 404
    assert not (await client.get(base, headers=_as(other))).json()["data"]
    async with async_session_maker() as session:
        assert (await session.get(Memory, _u(mid))).visibility == "private"
        media = await session.get(MemoryMedia, _u(detail["media"][0]["id"]))
        assert await storage.exists(media.storage_key)


async def test_delete_account_anonymizes_chat_snapshots_and_preserves_images(
    client: AsyncClient,
) -> None:
    owner, other = await _new_user(), await _new_user()
    fid = await _create_family(client, owner)
    await _join(client, fid, owner, other)
    base = f"/api/v1/families/{fid}/plugins/chat/messages"
    own = await client.post(base, json={"client_id": "own", "body": "我的消息"}, headers=_as(owner))
    theirs = await client.post(
        base, json={"client_id": "other", "body": "家人的消息"}, headers=_as(other)
    )
    image = await client.post(
        f"{base}/image",
        data={"client_id": "image"},
        headers=_as(owner),
        files={"file": ("photo.png", _png(), "image/png")},
    )
    assert image.status_code == 201, image.text
    resp = await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(owner))
    assert resp.status_code == 200, resp.text
    listing = (await client.get(base, headers=_as(other))).json()
    assert len(listing["data"]) == 3
    for row in listing["data"]:
        if row["sender_id"] == owner:
            assert row["sender_name"] == ANONYMOUS_MEMBER.name
            assert row["sender_emoji"] == ANONYMOUS_MEMBER.emoji
            assert row["sender_avatar_url"] is None
        else:
            assert row["sender_name"] == theirs.json()["data"]["sender_name"]
    assert (
        await client.get(image.json()["data"]["image"]["url"], headers=_as(other))
    ).content == _png()
    async with async_session_maker() as session:
        stored = await session.get(ChatMessage, _u(own.json()["data"]["id"]))
        assert stored.body == "我的消息"
        assert stored.sender_name == ANONYMOUS_MEMBER.name
    # 即使没有新消息，也必须通知 App 更新缓存中已退出成员的历史身份。
    last = listing["data"][-1]
    empty = await client.get(
        base,
        headers=_as(other),
        params={"after_created_at": last["created_at"], "after_id": last["id"]},
    )
    assert empty.json()["data"] == []
    assert empty.json()["meta"]["active_member_ids"] == [other]


@pytest.mark.parametrize(
    ("path", "payload", "name_field"),
    [
        ("accounting/transactions", {"amount": "12.50", "category": "dining"}, "creator_name"),
        ("recipe/recipes", {"name": "家常菜"}, "creator_name"),
        ("retirement/accounts", {"name": "存款", "balance": "1000"}, "creator_name"),
        ("chore/chores", {"title": "扫地"}, None),
        ("calendar/items", {"title": "家庭日程"}, None),
    ],
)
async def test_delete_account_preserves_other_plugin_records(
    client: AsyncClient,
    path: str,
    payload: dict,
    name_field: str | None,
) -> None:
    owner, other = await _new_user(), await _new_user()
    fid = await _create_family(client, owner)
    await _join(client, fid, owner, other)
    base = f"/api/v1/families/{fid}/plugins/{path}"
    created = await client.post(base, json=payload, headers=_as(owner))
    assert created.status_code == 201, created.text
    record = created.json()["data"]
    deleted = await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(owner))
    assert deleted.status_code == 200, deleted.text
    rows = (await client.get(base, headers=_as(other))).json()["data"]
    after = next(row for row in rows if row["id"] == record["id"])
    assert after["created_by"] == owner
    for field, value in payload.items():
        assert after[field] == record[field], value
    if name_field:
        assert after[name_field] == ANONYMOUS_MEMBER.name
        assert after["creator_avatar_url"] is None


async def test_delete_account_rolls_back_if_anonymization_fails(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    uid = await _new_user()

    async def fail(session, user_id):
        raise RuntimeError("snapshot update failed")

    monkeypatch.setattr(registry, "anonymize_user_hooks", lambda: [fail])
    with pytest.raises(RuntimeError, match="snapshot update failed"):
        await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(uid))
    async with async_session_maker() as session:
        row = await session.get(User, _u(uid))
        assert row.deleted_at is None
        assert row.password_hash is not None


async def test_delete_account_transfers_ownership(client: AsyncClient) -> None:
    """主理人注销不能把家丢下没人管 —— 要自动移交给资历最老的成员。"""
    owner = await _new_user()
    other = await _new_user()
    fid = await _create_family(client, owner)
    await _join(client, fid, owner, other)

    resp = await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(owner))
    assert resp.status_code == 200, resp.text
    assert resp.json()["data"]["ownerships_transferred"] == 1

    async with async_session_maker() as session:
        heir = (
            await session.execute(
                select(Membership).where(
                    Membership.family_id == uuid.UUID(fid),
                    Membership.user_id == uuid.UUID(other),
                )
            )
        ).scalar_one()
        assert heir.role == "owner", "主理人应已移交"
        gone = (
            await session.execute(select(Membership).where(Membership.user_id == uuid.UUID(owner)))
        ).scalar_one_or_none()
        assert gone is None, "注销者不应还留在家庭里"
        assert (await session.get(Family, _u(fid))) is not None, "家还在"


async def test_delete_account_dissolves_solo_family(client: AsyncClient) -> None:
    """独苗家庭：人走了，这个家也就不存在了（否则留一堆没人管的孤儿数据）。"""
    uid = await _new_user()
    fid = await _create_family(client, uid)

    resp = await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(uid))
    assert resp.status_code == 200, resp.text
    assert resp.json()["data"]["families_dissolved"] == 1

    async with async_session_maker() as session:
        assert (await session.get(Family, _u(fid))) is None


async def test_delete_account_invalidates_all_sessions(client: AsyncClient) -> None:
    """注销后，之前签发的 token 必须立刻失效（所有端）。"""
    uid = await _new_user()
    async with async_session_maker() as session:
        token = await issue_session(session, _u(uid), ttl_days=1, client="mp")

    authed = await client.get("/api/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert authed.status_code == 200, "前置条件：token 应该能用"

    await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(uid))

    after = await client.get("/api/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert after.status_code == 401, "注销后旧 token 必须失效"


async def test_delete_account_anonymizes_and_releases_identifiers(
    client: AsyncClient,
) -> None:
    """身份数据清空：不能登录、手机号与微信标识释放（可被重新注册）。"""
    uid = await _new_user()
    async with async_session_maker() as session:
        user = (await session.execute(select(User).where(User.id == _u(uid)))).scalar_one()
        phone = user.phone
        user.wechat_openid = f"o-test-{uuid.uuid4().hex[:12]}"
        await session.commit()

    resp = await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(uid))
    assert resp.status_code == 200, resp.text

    async with async_session_maker() as session:
        row = (await session.execute(select(User).where(User.id == _u(uid)))).scalar_one()
        # 行还在（历史外键需要它），但已经不含任何个人信息
        assert row.deleted_at is not None, "应标记为已注销"
        assert row.phone is None, "手机号必须释放"
        assert row.password_hash is None, "不能再登录"
        assert row.wechat_openid is None, "微信绑定必须释放"
        assert row.display_name == "已注销用户"
        assert row.username.startswith("deleted_")

    # 手机号释放后，同号可以作为全新账号重新注册（登录接口是 login_or_register）
    relogin = await client.post(
        "/api/v1/auth/login", json={"phone": phone, "password": "whatever1"}
    )
    assert relogin.status_code in (200, 201), relogin.text
    assert relogin.json()["data"]["user"]["id"] != uid, "应是一个新账号"


async def test_delete_account_twice_is_rejected(client: AsyncClient) -> None:
    uid = await _new_user()
    first = await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(uid))
    assert first.status_code == 200, first.text

    second = await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(uid))
    assert second.status_code == 409


@pytest.mark.parametrize("missing", ["", None])
async def test_delete_account_rejects_empty_password(
    client: AsyncClient, missing: str | None
) -> None:
    uid = await _new_user()
    body = {} if missing is None else {"password": missing}
    resp = await client.post(DELETE_URL, json=body, headers=_as(uid))
    assert resp.status_code == 422, "空密码要被 schema 挡住，不能落到服务层"
