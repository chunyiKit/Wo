"""账号注销测试。

合规要求（微信《常见拒绝情形》3.4.1 / PIPL 第 47 条）说「注销后应删除相关
数据」—— 所以这里断言的是**真的没了**：行没了、COS 对象没了、会话没了、
手机号和微信标识被释放。任何一项只做了一半，测试就必须红。
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
from app.plugins.memory.models import Memory, MemoryMedia
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


async def _memory_with_photo(client: AsyncClient, fid: str, author: str, title: str) -> str:
    """发一条带照片的回忆，返回 memory_id。"""
    created = await client.post(
        MEM_BASE.format(fid=fid), json={"title": title}, headers=_as(author)
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


async def test_delete_account_erases_own_content_but_not_others(
    client: AsyncClient,
) -> None:
    """最核心的一条：我发的内容全没了，别人发的一条不少。"""
    owner = await _new_user()
    other = await _new_user()
    fid = await _create_family(client, owner)
    await _join(client, fid, owner, other)

    mine = await _memory_with_photo(client, fid, owner, "我的回忆")
    theirs = await _memory_with_photo(client, fid, other, "别人的回忆")

    resp = await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(owner))
    assert resp.status_code == 200, resp.text

    async with async_session_maker() as session:
        remaining = (
            await session.execute(select(Memory.id).where(Memory.family_id == _u(fid)))
        ).scalars().all()
        assert [str(m) for m in remaining] == [theirs], "只应留下别人的那条"
        media = (
            await session.execute(
                select(MemoryMedia.storage_key).where(MemoryMedia.family_id == _u(fid))
            )
        ).scalars().all()
        assert len(media) == 1, "只应留下别人那张照片的对象"
        assert mine not in [str(m) for m in remaining]


async def test_delete_account_removes_storage_objects(client: AsyncClient) -> None:
    """行删了但对象还在 = 没删干净。这是最容易漏的一处。"""
    uid = await _new_user()
    fid = await _create_family(client, uid)
    await _memory_with_photo(client, fid, uid, "带照片的")

    async with async_session_maker() as session:
        keys = (
            await session.execute(
                select(MemoryMedia.storage_key).where(MemoryMedia.family_id == _u(fid))
            )
        ).scalars().all()
    assert keys, "前置条件：应该有一张照片"
    assert all([await storage.exists(k) for k in keys])

    resp = await client.post(DELETE_URL, json={"password": PASSWORD}, headers=_as(uid))
    assert resp.status_code == 200, resp.text
    assert resp.json()["data"]["storage_objects_deleted"] >= 1

    for key in keys:
        assert not await storage.exists(key), f"对象 {key} 应该已经被删除"


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
            await session.execute(
                select(Membership).where(Membership.user_id == uuid.UUID(owner))
            )
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
