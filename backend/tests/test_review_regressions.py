"""注销、微信认证、家庭移交与直传的并发及数据完整性回归。"""

import asyncio
import uuid
from datetime import date

import pytest
from sqlalchemy import select

from app.api.v1.routes import wechat as wechat_routes
from app.core.database import async_session_maker
from app.core.storage import COSStorage, storage
from app.models.family import Family
from app.models.membership import Membership
from app.models.pet import Pet
from app.models.user import User
from app.plugins.memory.models import Memory, MemoryMedia
from app.plugins.photo.models import Photo
from app.plugins.plant.models import Plant, PlantLog
from app.services import account as account_service
from app.services import auth as auth_service
from app.services import wechat as wechat_service
from app.services.wechat import WeChatSession
from tests.test_memory_direct_upload import FakeDirectStorage, _png

PASSWORD = "synthetic-test-password"
DELETE = "/api/v1/me/delete-account"


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


async def make_family(client, token, other_id=None):
    result = await client.post("/api/v1/families", json={"name": "并发回归"}, headers=bearer(token))
    assert result.status_code == 201, result.text
    fid = uuid.UUID(result.json()["data"]["id"])
    if other_id:
        async with async_session_maker() as session:
            session.add(Membership(user_id=other_id, family_id=fid, display_name="家人"))
            await session.commit()
    return fid


def pause_first(monkeypatch, module, name):
    original = getattr(module, name)
    entered, release = asyncio.Event(), asyncio.Event()
    first = True

    async def gated(*args, **kwargs):
        nonlocal first
        if first:
            first = False
            entered.set()
            await release.wait()
        return await original(*args, **kwargs)

    monkeypatch.setattr(module, name, gated)
    return entered, release


async def test_delete_rechecks_session_after_waiting_for_user_lock(
    client,
    authenticated_account_factory,
    monkeypatch,
):
    uid, token = await authenticated_account_factory()
    entered, release = pause_first(monkeypatch, auth_service, "locked_user")
    pending = asyncio.create_task(
        client.post(DELETE, headers=bearer(token), json={"password": PASSWORD})
    )
    try:
        await asyncio.wait_for(entered.wait(), 3)
        changed = await client.post(
            "/api/v1/auth/change-password",
            headers=bearer(token),
            json={"old_password": PASSWORD, "new_password": "updated-password"},
        )
        assert changed.status_code == 200, changed.text
    finally:
        release.set()
    deleted = await asyncio.wait_for(pending, 3)
    assert deleted.status_code == 401
    assert deleted.json()["error"]["details"]["session_invalid"] is True
    async with async_session_maker() as session:
        assert (await session.get(User, uid)).deleted_at is None


async def bound_identity(monkeypatch, uid):
    openid = "cr-" + uuid.uuid4().hex
    async with async_session_maker() as session:
        user = await session.get(User, uid)
        user.wechat_openid = openid
        await session.commit()

    async def exchange(code):
        return WeChatSession(openid=openid)

    monkeypatch.setattr(wechat_service, "code_to_session", exchange)
    return openid


@pytest.mark.parametrize("mutation", ["unbind", "delete"])
async def test_silent_login_cannot_issue_session_for_removed_identity(
    client,
    authenticated_account_factory,
    monkeypatch,
    mutation,
):
    uid, token = await authenticated_account_factory()
    await bound_identity(monkeypatch, uid)
    entered, release = pause_first(monkeypatch, wechat_routes, "_locked_user")
    pending = asyncio.create_task(
        client.post("/api/v1/auth/wechat/login", json={"code": "one-shot"})
    )
    try:
        await asyncio.wait_for(entered.wait(), 3)
        if mutation == "unbind":
            result = await client.delete("/api/v1/me/wechat", headers=bearer(token))
        else:
            result = await client.post(DELETE, headers=bearer(token), json={"password": PASSWORD})
        assert result.status_code == 200, result.text
    finally:
        release.set()
    result = await asyncio.wait_for(pending, 3)
    assert result.status_code == 200, result.text
    assert result.json()["data"]["bound"] is False
    assert result.json()["data"]["token"] is None


@pytest.mark.parametrize("mutation", ["delete", "unbind", "password"])
async def test_bind_revalidates_account_and_credentials_after_lock(
    client,
    authenticated_account_factory,
    monkeypatch,
    mutation,
):
    uid, token = await authenticated_account_factory()
    await bound_identity(monkeypatch, uid)
    entered, release = pause_first(monkeypatch, wechat_routes, "_locked_user")
    pending = asyncio.create_task(
        client.post(
            "/api/v1/auth/wechat/bind",
            json={"code": "one-shot", "phone": "13900000001", "password": PASSWORD},
        )
    )
    try:
        await asyncio.wait_for(entered.wait(), 3)
        if mutation == "delete":
            result = await client.post(DELETE, headers=bearer(token), json={"password": PASSWORD})
        elif mutation == "unbind":
            result = await client.delete("/api/v1/me/wechat", headers=bearer(token))
        else:
            result = await client.post(
                "/api/v1/auth/change-password",
                headers=bearer(token),
                json={"old_password": PASSWORD, "new_password": "updated-password"},
            )
        assert result.status_code == 200, result.text
    finally:
        release.set()
    result = await asyncio.wait_for(pending, 3)
    assert result.status_code in (401, 409), result.text
    if mutation in ("delete", "unbind"):
        async with async_session_maker() as session:
            assert (await session.get(User, uid)).wechat_openid is None


@pytest.mark.parametrize("first_owner", [True, False])
async def test_concurrent_last_members_delete_without_orphan_family(
    client,
    authenticated_account_factory,
    monkeypatch,
    first_owner,
):
    owner, owner_token = await authenticated_account_factory()
    other, other_token = await authenticated_account_factory()
    fid = await make_family(client, owner_token, other)
    original = account_service.lock_family_memberships
    acquired, requested, release = asyncio.Event(), asyncio.Event(), asyncio.Event()
    count = 0

    async def lock(session, family_id):
        nonlocal count
        count += 1
        first = count == 1
        if not first:
            requested.set()
        await original(session, family_id)
        if first:
            acquired.set()
            await release.wait()

    monkeypatch.setattr(account_service, "lock_family_memberships", lock)
    tokens = (owner_token, other_token) if first_owner else (other_token, owner_token)
    first = asyncio.create_task(
        client.post(DELETE, headers=bearer(tokens[0]), json={"password": PASSWORD})
    )
    await asyncio.wait_for(acquired.wait(), 3)
    second = asyncio.create_task(
        client.post(DELETE, headers=bearer(tokens[1]), json={"password": PASSWORD})
    )
    try:
        await asyncio.wait_for(requested.wait(), 3)
    finally:
        release.set()
    results = await asyncio.wait_for(asyncio.gather(first, second), 5)
    assert [r.status_code for r in results] == [200, 200], [r.text for r in results]
    assert sum(r.json()["data"]["families_dissolved"] for r in results) == 1
    async with async_session_maker() as session:
        assert await session.get(Family, fid) is None
        assert not (
            await session.execute(select(Membership).where(Membership.family_id == fid))
        ).all()


@pytest.mark.parametrize("shared_legacy_photo", [False, True])
async def test_solo_family_deletes_all_registered_media_after_commit(
    client,
    authenticated_account_factory,
    shared_legacy_photo,
):
    owner, token = await authenticated_account_factory()
    former, other_token = await authenticated_account_factory()
    fid = await make_family(client, token)
    prefix = f"cr-cleanup/{fid}"
    keys = [
        f"{prefix}/{name}.png"
        for name in ("memory", "background", "photo", "plant", "log1", "log2")
    ]
    other_family = await make_family(client, other_token) if shared_legacy_photo else None
    async with async_session_maker() as session:
        family = await session.get(Family, fid)
        family.background_storage_key = keys[1]
        memory = Memory(
            family_id=fid, title="离家成员的回忆", created_by=former, event_date=date.today()
        )
        plant = Plant(family_id=fid, name="绿萝", cover_storage_key=keys[3])
        session.add_all([memory, plant])
        await session.flush()
        session.add(
            MemoryMedia(
                memory_id=memory.id,
                family_id=fid,
                storage_key=keys[0],
                content_type="image/png",
                size_bytes=1,
                created_by=former,
            )
        )
        session.add(
            Photo(
                family_id=fid,
                storage_key=keys[2],
                content_type="image/png",
                size_bytes=1,
                uploaded_by=former,
            )
        )
        session.add(
            PlantLog(
                plant_id=plant.id,
                family_id=fid,
                photo_storage_key=keys[4],
                photos=[{"key": keys[4]}, {"key": keys[5]}],
            )
        )
        if other_family:
            session.add(Pet(family_id=other_family, name="旧版宠物照片", photo_storage_key=keys[2]))
        await session.commit()
    for key in keys:
        await storage.put(key, _png(), "image/png")
    result = await client.post(DELETE, headers=bearer(token), json={"password": PASSWORD})
    assert result.status_code == 200, result.text
    assert result.json()["data"]["storage_objects_deleted"] == len(keys) - int(shared_legacy_photo)
    assert [await storage.exists(key) for key in keys] == [
        shared_legacy_photo and i == 2 for i in range(len(keys))
    ]


async def test_direct_tickets_cannot_overwrite_committed_or_other_authors_media(
    client,
    authenticated_account_factory,
    monkeypatch,
):
    owner, token = await authenticated_account_factory()
    other, other_token = await authenticated_account_factory()
    fid = await make_family(client, token, other)
    base = f"/api/v1/families/{fid}/plugins/memory/memories"
    mid = (await client.post(base, json={"title": "不可覆盖"}, headers=bearer(token))).json()[
        "data"
    ]["id"]
    url = f"{base}/{mid}/media"
    fake = FakeDirectStorage()
    monkeypatch.setattr("app.plugins.memory.routes.storage", fake)
    media_id = str(uuid.uuid4())
    tickets = []
    for t in (token, other_token):
        response = await client.post(
            f"{url}/presign",
            headers=bearer(t),
            json={"client_id": media_id, "content_type": "image/png"},
        )
        assert response.status_code == 200, response.text
        tickets.append(response.json()["data"])
    assert tickets[0]["key"] != tickets[1]["key"]
    fake.objects[tickets[0]["key"]] = _png()
    body = {"media_id": media_id, "key": tickets[0]["key"], "content_type": "image/png"}
    committed = await client.post(f"{url}/commit", headers=bearer(token), json=body)
    assert committed.status_code == 201, committed.text
    final_key = fake.copies[0][1]
    # 重放旧票据能改变暂存对象，但不能改变最终对象；幂等重试返回首次提交结果。
    fake.objects[tickets[0]["key"]] = b"malicious replacement"
    repeated = await client.post(f"{url}/commit", headers=bearer(token), json=body)
    assert repeated.json()["data"] == committed.json()["data"]
    fake.objects[tickets[1]["key"]] = b"another author"
    collision = await client.post(
        f"{url}/commit", headers=bearer(other_token), json={**body, "key": tickets[1]["key"]}
    )
    assert collision.status_code == 409
    for t in (token, other_token):
        rejected = await client.post(
            f"{url}/presign",
            headers=bearer(t),
            json={"client_id": media_id, "content_type": "image/png"},
        )
        assert rejected.status_code == 409
    assert fake.objects[final_key] == _png()
    assert len(fake.copies) == 1


def test_cos_copy_pins_verified_source_and_private_acl():
    class SDK:
        def copy_object(self, **kwargs):
            self.kwargs = kwargs

    cos = COSStorage.__new__(COSStorage)
    cos._bucket, cos._region, cos._client = "synthetic-bucket", "ap-test", SDK()
    asyncio.run(cos.copy("staging", "final", etag='"verified-etag"'))
    assert cos._client.kwargs["CopySourceIfMatch"] == '"verified-etag"'
    assert cos._client.kwargs["ACL"] == "private"
    assert cos._client.kwargs["CopySource"]["Key"] == "staging"
    assert cos._client.kwargs["Key"] == "final"
