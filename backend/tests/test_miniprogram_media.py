"""小程序鉴权媒体下载回归：仅使用内存 SQLite 与假 COS，不启动应用 lifespan。

身份依赖使用固定测试身份；家庭成员查询仍运行真实 require_membership SQL，
资源归属与 private 可见性仍运行真实路由逻辑。不会连接 PostgreSQL 或外部存储。
"""

from datetime import date
from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine
from sqlmodel import Session

from app.api.v1.routes import families, me, members
from app.core.auth import get_current_user
from app.core.config import settings
from app.core.database import get_session
from app.core.errors import register_exception_handlers
from app.models.family import Family
from app.models.membership import Membership
from app.models.user import User
from app.plugins.memory import routes as memory_routes
from app.plugins.memory.models import Memory, MemoryMedia


class FakeCOS:
    def __init__(self):
        self.reads = []
        self.presigns = []
        self.missing = False

    async def get(self, key):
        self.reads.append(key)
        if self.missing:
            raise FileNotFoundError(key)
        return b"private-image-bytes"

    async def presigned_get_url(self, key, *, ttl_seconds):
        self.presigns.append((key, ttl_seconds))
        return "https://private-cos.example/image?temporary_signature=test"


class MediaSession:
    """只把 membership SQL 交给内存 SQLite，其余模型从测试对象表加载。"""

    def __init__(self, sql_session, objects):
        self.sql_session = sql_session
        self.objects = {(type(obj), obj.id): obj for obj in objects}

    async def execute(self, statement):
        return self.sql_session.execute(statement)

    async def get(self, model, key):
        return self.objects.get((model, key))


@pytest.fixture
async def media_case(monkeypatch):
    viewer = User(
        username="viewer",
        display_name="查看者",
        avatar_storage_key="avatars/self",
        avatar_content_type="image/png",
        avatar_version=2,
    )
    author = User(
        username="author",
        display_name="作者",
        avatar_storage_key="avatars/author",
        avatar_content_type="image/png",
        avatar_version=3,
    )
    outsider = User(username="outsider", display_name="其他家庭成员")
    family_id = uuid4()
    family = Family(
        id=family_id,
        name="测试家庭",
        owner_user_id=author.id,
        background_storage_key="backgrounds/family",
        background_content_type="image/png",
        background_version=4,
    )
    memory = Memory(
        family_id=family_id,
        title="测试",
        event_date=date(2026, 1, 1),
        created_by=author.id,
        visibility="family",
    )
    media = MemoryMedia(
        family_id=family_id,
        memory_id=memory.id,
        storage_key="memories/image",
        content_type="image/png",
        kind="photo",
    )
    storage = FakeCOS()
    for module in (me, members, memory_routes):
        monkeypatch.setattr(module, "storage", storage)
    monkeypatch.setattr(families.storage_module, "storage", storage)

    engine = create_engine("sqlite:///:memory:")
    # 不创建 User/Family 等 PG 表，不运行迁移，也不连接全局 engine。
    Membership.__table__.create(engine)
    with Session(engine) as sql_session:
        for user in (viewer, author):
            sql_session.add(
                Membership(
                    user_id=user.id,
                    family_id=family_id,
                    display_name=user.display_name,
                    role="member",
                )
            )
        sql_session.commit()
        session = MediaSession(sql_session, [viewer, author, outsider, family, memory, media])
        case = SimpleNamespace(
            viewer=viewer,
            author=author,
            outsider=outsider,
            current_user=viewer,
            family=family,
            memory=memory,
            media=media,
            session=session,
            storage=storage,
        )
        app = FastAPI()
        register_exception_handlers(app)
        for router in (me.router, members.router, families.router, memory_routes.router):
            app.include_router(router, prefix="/api/v1")

        async def test_session():
            return session

        async def test_identity():
            return case.current_user

        app.dependency_overrides[get_session] = test_session
        app.dependency_overrides[get_current_user] = test_identity
        case.app = app
        async with AsyncClient(
            transport=ASGITransport(app=app), base_url="http://test", follow_redirects=False
        ) as client:
            case.client = client
            case.urls = {
                "self": "/api/v1/me/avatar?v=2",
                "member": f"/api/v1/families/{family_id}/members/{author.id}/avatar?v=3",
                "background": f"/api/v1/families/{family_id}/background?v=4",
                "memory": f"/api/v1/families/{family_id}/plugins/memory/memories/"
                f"{memory.id}/media/{media.id}/raw?v=1",
            }
            yield case
    engine.dispose()


@pytest.mark.parametrize("kind", ["self", "member", "background", "memory"])
async def test_download_returns_private_bytes_without_cos_redirect(media_case, kind):
    response = await media_case.client.get(media_case.urls[kind] + "&download=true")
    assert response.status_code == 200
    assert response.content == b"private-image-bytes"
    assert response.headers["content-type"] == "image/png"
    assert response.headers["cache-control"] == "private, no-store"
    assert "location" not in response.headers
    assert len(media_case.storage.reads) == 1
    assert media_case.storage.presigns == []


@pytest.mark.parametrize("kind", ["self", "member", "background", "memory"])
@pytest.mark.parametrize("query", ["", "&download=false"])
async def test_default_cos_download_preserves_app_redirect(media_case, kind, query):
    response = await media_case.client.get(media_case.urls[kind] + query)
    assert response.status_code == 302
    assert response.headers["location"].startswith("https://private-cos.example/")
    assert "Bearer" not in response.headers["location"]
    assert response.headers["cache-control"] == "private, no-store"
    assert media_case.storage.reads == []
    assert len(media_case.storage.presigns) == 1


@pytest.mark.parametrize("kind", ["member", "background", "memory"])
@pytest.mark.parametrize("download", ["true", "false"])
async def test_cross_family_viewer_cannot_read_or_presign(media_case, kind, download):
    media_case.current_user = media_case.outsider
    response = await media_case.client.get(media_case.urls[kind] + f"&download={download}")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "FAMILY_NOT_FOUND"
    assert media_case.storage.reads == media_case.storage.presigns == []


@pytest.mark.parametrize("download", ["true", "false"])
async def test_member_avatar_target_must_be_in_family(media_case, download):
    url = media_case.urls["member"].replace(str(media_case.author.id), str(media_case.outsider.id))
    response = await media_case.client.get(url + f"&download={download}")
    assert response.status_code == 404
    assert media_case.storage.reads == media_case.storage.presigns == []


@pytest.mark.parametrize("download", ["true", "false"])
async def test_private_memory_only_author_can_download(media_case, download):
    media_case.memory.visibility = "private"
    response = await media_case.client.get(media_case.urls["memory"] + f"&download={download}")
    assert response.status_code == 404
    assert media_case.storage.reads == media_case.storage.presigns == []
    media_case.current_user = media_case.author
    response = await media_case.client.get(media_case.urls["memory"] + f"&download={download}")
    assert response.status_code == (200 if download == "true" else 302)


@pytest.mark.parametrize("resource", ["media_family", "media_memory", "memory_family"])
async def test_mismatched_memory_attachment_cannot_be_downloaded(media_case, resource):
    if resource == "media_family":
        media_case.media.family_id = uuid4()
    elif resource == "media_memory":
        media_case.media.memory_id = uuid4()
    else:
        media_case.memory.family_id = uuid4()
    response = await media_case.client.get(media_case.urls["memory"] + "&download=true")
    assert response.status_code == 404
    assert media_case.storage.reads == media_case.storage.presigns == []


async def test_background_stale_version_does_not_resolve(media_case):
    response = await media_case.client.get(
        media_case.urls["background"].replace("v=4", "v=3") + "&download=true"
    )
    assert response.status_code == 404
    assert media_case.storage.reads == media_case.storage.presigns == []


@pytest.mark.parametrize("kind", ["self", "member", "background", "memory"])
async def test_missing_download_never_falls_back_to_redirect(media_case, kind):
    media_case.storage.missing = True
    response = await media_case.client.get(media_case.urls[kind] + "&download=true")
    assert response.status_code == (404 if kind == "background" else 500)
    assert media_case.storage.presigns == []


@pytest.mark.parametrize("kind", ["self", "member", "background", "memory"])
async def test_download_requires_real_auth_when_not_overridden(media_case, kind, monkeypatch):
    monkeypatch.setattr(settings, "auth_dev_shim_enabled", False)
    del media_case.app.dependency_overrides[get_current_user]
    response = await media_case.client.get(media_case.urls[kind] + "&download=true")
    assert response.status_code == 401
    assert media_case.storage.reads == media_case.storage.presigns == []


@pytest.mark.parametrize("kind", ["self", "member", "background", "memory"])
@pytest.mark.parametrize("download", ["true", "false"])
async def test_local_storage_remains_inline_and_private(media_case, kind, download, monkeypatch):
    local_storage = SimpleNamespace(get=media_case.storage.get)
    for module in (me, members, memory_routes):
        monkeypatch.setattr(module, "storage", local_storage)
    monkeypatch.setattr(families.storage_module, "storage", local_storage)
    response = await media_case.client.get(media_case.urls[kind] + f"&download={download}")
    assert response.status_code == 200
    assert response.content == b"private-image-bytes"
    assert response.headers["cache-control"].startswith("private,")
    if download == "true":
        assert response.headers["cache-control"] == "private, no-store"
    assert "location" not in response.headers
