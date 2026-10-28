"""微信小程序账号互通：静默登录 / 绑定 / 绑定状态 / 解绑。

`code_to_session` 是唯一打微信外网的环节，测试里 monkeypatch 掉 —— 我们校验的是
「拿到身份之后」的绑定语义，不是微信自己的接口。
"""

import random

import pytest
from httpx import AsyncClient

from app.services import wechat as wechat_service
from app.services.wechat import WeChatSession

PW = "secret123"


def _random_phone() -> str:
    return "1" + str(random.randint(3, 9)) + "".join(str(random.randint(0, 9)) for _ in range(9))


def _random_openid() -> str:
    return "openid-" + "".join(random.choice("abcdef0123456789") for _ in range(24))


@pytest.fixture
def fake_wechat(monkeypatch):
    """Patch the upstream exchange. Returns a setter for the next identity."""
    current = {"openid": _random_openid(), "unionid": None}

    async def _fake(code: str) -> WeChatSession:
        assert code, "小程序必须带上 wx.login() 的 code"
        return WeChatSession(openid=current["openid"], unionid=current["unionid"])

    monkeypatch.setattr(wechat_service, "code_to_session", _fake)
    # 路由模块是在函数体内通过模块属性调用的（wechat_service.code_to_session），
    # 所以 patch 模块属性即可生效，不需要 patch 路由模块本身。

    def set_identity(openid: str | None = None, unionid: str | None = None) -> WeChatSession:
        current["openid"] = openid or _random_openid()
        current["unionid"] = unionid
        return WeChatSession(openid=current["openid"], unionid=current["unionid"])

    return set_identity


# ---- A1 静默登录 -------------------------------------------------------------


async def test_wechat_login_unbound(client: AsyncClient, fake_wechat) -> None:
    res = await client.post("/api/v1/auth/wechat/login", json={"code": "some-code"})
    assert res.status_code == 200
    data = res.json()["data"]
    assert data["bound"] is False
    assert data["user"] is None and data["token"] is None


async def test_wechat_login_bound_returns_token(client: AsyncClient, fake_wechat) -> None:
    ws = fake_wechat()
    bound = await client.post(
        "/api/v1/auth/wechat/bind",
        json={"code": "c", "phone": _random_phone(), "password": PW},
    )
    assert bound.status_code == 200
    user_id = bound.json()["data"]["user"]["id"]

    res = await client.post("/api/v1/auth/wechat/login", json={"code": "another-code"})
    assert res.status_code == 200
    data = res.json()["data"]
    assert data["bound"] is True
    assert data["user"]["id"] == user_id
    assert data["token"]

    assert ws.openid  # sanity: the fixture produced an identity


async def test_wechat_login_marks_session_as_mp(client: AsyncClient, fake_wechat) -> None:
    from sqlalchemy import select

    from app.core.database import async_session_maker
    from app.models.auth_session import AuthSession

    fake_wechat()
    bound = await client.post(
        "/api/v1/auth/wechat/bind",
        json={"code": "c", "phone": _random_phone(), "password": PW},
    )
    token = bound.json()["data"]["token"]
    import hashlib

    token_hash = hashlib.sha256(token.encode()).hexdigest()
    async with async_session_maker() as session:
        row = (
            await session.execute(select(AuthSession).where(AuthSession.token_hash == token_hash))
        ).scalar_one()
    assert row.client == "mp"


async def test_wechat_login_requires_code(client: AsyncClient, fake_wechat) -> None:
    res = await client.post("/api/v1/auth/wechat/login", json={"code": ""})
    assert res.status_code == 422


async def test_wechat_login_not_configured(client: AsyncClient, monkeypatch) -> None:
    """缺少 AppID/AppSecret 时给运维能看懂的 503，而不是拿空密钥去撞微信。"""
    from app.core.config import settings

    monkeypatch.setattr(settings, "wechat_app_id", "")
    res = await client.post("/api/v1/auth/wechat/login", json={"code": "c"})
    assert res.status_code == 503
    assert res.json()["error"]["code"] == "WECHAT_NOT_CONFIGURED"


# ---- A2 绑定 -----------------------------------------------------------------


async def test_bind_registers_new_account(client: AsyncClient, fake_wechat) -> None:
    ws = fake_wechat()
    phone = _random_phone()
    res = await client.post(
        "/api/v1/auth/wechat/bind",
        json={"code": "c", "phone": phone, "password": PW},
    )
    assert res.status_code == 200
    data = res.json()["data"]
    assert data["is_new"] is True
    assert data["token"]

    # 绑定后静默登录即可命中同一账号 —— 这就是「下次打开零输入」的保证。
    again = await client.post("/api/v1/auth/wechat/login", json={"code": "c2"})
    assert again.json()["data"]["user"]["id"] == data["user"]["id"]
    assert ws.openid


async def test_bind_existing_account(client: AsyncClient, fake_wechat) -> None:
    phone = _random_phone()
    first = await client.post("/api/v1/auth/login", json={"phone": phone, "password": PW})
    user_id = first.json()["data"]["user"]["id"]

    fake_wechat()
    res = await client.post(
        "/api/v1/auth/wechat/bind",
        json={"code": "c", "phone": phone, "password": PW},
    )
    assert res.status_code == 200
    assert res.json()["data"]["user"]["id"] == user_id
    assert res.json()["data"]["is_new"] is False


async def test_bind_wrong_password_rejected(client: AsyncClient, fake_wechat) -> None:
    phone = _random_phone()
    await client.post("/api/v1/auth/login", json={"phone": phone, "password": PW})

    fake_wechat()
    res = await client.post(
        "/api/v1/auth/wechat/bind",
        json={"code": "c", "phone": phone, "password": "wrongpass"},
    )
    assert res.status_code == 401


async def test_bind_rejects_identity_already_bound_elsewhere(
    client: AsyncClient, fake_wechat
) -> None:
    """一个微信身份只能绑一个 Wo 账号：拿另一个账号的凭据去绑，应该 409。

    注意两个账号必须用**不同**的密码 —— 若密码恰好相同，那是「用 A 的密码登录
    A」的合法路径（等价于普通密码登录），会走幂等返回而不是冲突。
    """
    ws = fake_wechat()
    await client.post(
        "/api/v1/auth/wechat/bind",
        json={"code": "c", "phone": _random_phone(), "password": PW},
    )

    other_phone = _random_phone()
    other_pw = "another-pass-456"
    await client.post("/api/v1/auth/login", json={"phone": other_phone, "password": other_pw})

    res = await client.post(
        "/api/v1/auth/wechat/bind",
        json={"code": "c2", "phone": other_phone, "password": other_pw},
    )
    assert res.status_code == 409
    assert res.json()["error"]["code"] == "WECHAT_OPENID_BOUND"
    assert ws.openid


async def test_bind_is_idempotent_on_retry(client: AsyncClient, fake_wechat) -> None:
    """重复绑定（用户手抖点两次）不该报错，应该回到同一个账号。"""
    ws = fake_wechat()
    phone = _random_phone()
    first = await client.post(
        "/api/v1/auth/wechat/bind",
        json={"code": "c", "phone": phone, "password": PW},
    )
    second = await client.post(
        "/api/v1/auth/wechat/bind",
        json={"code": "c2", "phone": phone, "password": PW},
    )
    assert second.status_code == 200
    assert second.json()["data"]["user"]["id"] == first.json()["data"]["user"]["id"]
    assert ws.openid


async def test_bind_finds_account_by_unionid(client: AsyncClient, fake_wechat) -> None:
    """只存了 unionid 的账号，靠 openid 查不到时要能回落。"""
    from sqlalchemy import select

    from app.core.database import async_session_maker
    from app.models.user import User

    # 测试库是共享的，unionid 必须每次不同，否则唯一约束会撞上前一次的残留。
    unionid = "unionid-only-" + "".join(random.choice("abcdef0123456789") for _ in range(12))
    phone = _random_phone()
    await client.post("/api/v1/auth/login", json={"phone": phone, "password": PW})
    async with async_session_maker() as session:
        user = (await session.execute(select(User).where(User.phone == phone))).scalar_one()
        user.wechat_unionid = unionid
        session.add(user)
        await session.commit()
        user_id = str(user.id)

    fake_wechat(unionid=unionid)
    res = await client.post("/api/v1/auth/wechat/login", json={"code": "c"})
    assert res.json()["data"]["bound"] is True
    assert res.json()["data"]["user"]["id"] == user_id


# ---- A4 / A5 绑定状态与解绑 ---------------------------------------------------


async def test_me_wechat_binding_state(
    client: AsyncClient, fake_wechat, authenticated_account_factory
) -> None:
    user_id, token = await authenticated_account_factory()
    headers = {"Authorization": f"Bearer {token}"}

    before = await client.get("/api/v1/me/wechat", headers=headers)
    assert before.json()["data"] == {"bound": False, "has_unionid": False}

    fake_wechat()
    await client.post(
        "/api/v1/auth/wechat/bind",
        json={"code": "c", "phone": _random_phone(), "password": PW},
    )
    # 换一个账号验证未绑定态不受影响
    after = await client.get("/api/v1/me/wechat", headers=headers)
    assert after.json()["data"]["bound"] is False


async def test_unbind_wechat_revokes_mp_sessions(client: AsyncClient, fake_wechat) -> None:
    from sqlalchemy import select

    from app.core.database import async_session_maker
    from app.models.auth_session import AuthSession

    fake_wechat()
    bound = await client.post(
        "/api/v1/auth/wechat/bind",
        json={"code": "c", "phone": _random_phone(), "password": PW},
    )
    token = bound.json()["data"]["token"]
    user_id = bound.json()["data"]["user"]["id"]
    headers = {"Authorization": f"Bearer {token}"}

    assert (await client.get("/api/v1/me/wechat", headers=headers)).json()["data"]["bound"]

    res = await client.delete("/api/v1/me/wechat", headers=headers)
    assert res.status_code == 200

    # 解绑后小程序会话被撤销：再打业务接口应该 401，而不是静默放行。
    after = await client.get("/api/v1/me/bootstrap", headers=headers)
    assert after.status_code == 401

    # 只针对这个账号断言 —— 测试库是共享的，别的用例也会留下 mp 会话。
    async with async_session_maker() as session:
        rows = (
            (
                await session.execute(
                    select(AuthSession).where(
                        AuthSession.user_id == user_id, AuthSession.client == "mp"
                    )
                )
            )
            .scalars()
            .all()
        )
    assert rows == []


async def test_unbind_requires_auth(client: AsyncClient, monkeypatch) -> None:
    """未登录不能解绑。conftest 默认开着 dev shim（免登录通道），这里显式关掉
    才能验到生产行为。"""
    from app.core.config import settings

    monkeypatch.setattr(settings, "auth_dev_shim_enabled", False)
    assert (await client.delete("/api/v1/me/wechat")).status_code == 401


async def test_unbind_without_binding_is_ok(
    client: AsyncClient, authenticated_account_factory
) -> None:
    _, token = await authenticated_account_factory()
    res = await client.delete("/api/v1/me/wechat", headers={"Authorization": f"Bearer {token}"})
    assert res.status_code == 200
    assert res.json()["data"]["unbound"] is True
