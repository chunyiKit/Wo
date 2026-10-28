"""微信小程序账号互通：静默登录、绑定、绑定状态查询与解绑。

四个端点放在一起（而不是拆进 auth.py / me.py）因为它们是一条完整的微信身份
生命周期，路径前缀却分属 `/auth/*` 与 `/me/*` 两个命名空间。

**首登策略 A（手机号 + 密码后绑定）**：
小程序先 `wx.login()` 拿 code 打 A1 —— 已绑定就直接拿 token 进主页（零输入）；
没绑定则弹出手机号/密码表单，用户填完打 A2 一次性完成「登录（或注册）+ 绑定」。
因此**没有独立的注册端点**：A2 复用 `login_or_register`，与 App 的注册语义一致
（未知手机号按新账号创建）。

关于 `resolve_user_id` 要求 `password_hash` 非空：策略 A 保证每个微信绑定用户都
是通过手机号+密码进来的，一定带密码，所以无需放宽该校验。若将来引入免密注册
（`getPhoneNumber` 一键，需企业主体）或扫码绑定，必须先改那里，否则会出现
「登录成功但每个请求都 401」——那正是当初把这个坑记下来的原因。

`wx.login()` 的 code 是一次性的（5 分钟有效）。A1 消耗掉一个之后，A2 必须再取
一个**新的** code，客户端在提交表单前重新 `wx.login()` 即可；服务端不做 ticket
状态，省一份需要清理的中间态。
"""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Header, Request
from pydantic import BaseModel, Field
from sqlalchemy import delete
from sqlalchemy.exc import IntegrityError
from sqlmodel import select

from app.api.deps import SessionDep
from app.core.auth import CurrentUserDep, parse_bearer
from app.core.config import settings
from app.core.errors import AppError, ErrorCode
from app.core.password import verify_password
from app.core.rate_limit import SlidingWindowRateLimiter, client_ip
from app.core.response import ApiResponse, ok
from app.models.auth_session import AuthSession
from app.models.user import User, UserRead
from app.services import auth as auth_service
from app.services import wechat as wechat_service
from app.services.session import CLIENT_MP, issue_session
from app.services.wechat import WeChatSession

router = APIRouter(tags=["wechat"])

# Throttle on the WeChat endpoints. Per-IP like the phone login limiter: the
# caller is anonymous until the code resolves, so there's no account key to
# throttle on yet. Generous ceiling — a user re-opening the mini program a few
# times must never trip it.
_wechat_ip_limiter = SlidingWindowRateLimiter(max_hits=30, window_seconds=60)


def _too_many() -> AppError:
    return AppError(ErrorCode.RATE_LIMIT, "操作过于频繁，请稍后再试", status_code=429)


# ---- Request / response shapes --------------------------------------------


class WeChatLoginRequest(BaseModel):
    code: str = Field(min_length=1, max_length=256)


class WeChatBindRequest(BaseModel):
    code: str = Field(min_length=1, max_length=256)
    phone: str = Field(max_length=32)
    password: str = Field(max_length=64)


class WeChatLoginResponse(BaseModel):
    """A1 result. `bound=False` means "no Wo account carries this WeChat
    identity" — the client then shows the phone/password form and calls A2.
    `user`/`token` are only populated when `bound` is True."""

    bound: bool
    user: UserRead | None = None
    token: str | None = None


class WeChatAuthResponse(BaseModel):
    """A2 result — same shape as the phone login response so the client's
    "store token, load bootstrap" path is literally the same code."""

    user: UserRead
    token: str
    is_new: bool


class WeChatBindingRead(BaseModel):
    bound: bool
    # False when we only hold an openid (e.g. bound before the mini program was
    # linked to the Open Platform). Cosmetic today; useful when diagnosing why
    # one identity didn't carry across.
    has_unionid: bool


# ---- Lookup -----------------------------------------------------------------


async def _find_bound_user(session: SessionDep, ws: WeChatSession) -> User | None:
    """Resolve a WeChat identity to a Wo account, or None when unbound.

    `openid` is checked first (always present), then `unionid` — so an account
    bound under either identifier is found.
    """
    row = (
        await session.execute(select(User).where(User.wechat_openid == ws.openid))
    ).scalar_one_or_none()
    if row is not None:
        return row
    if ws.unionid:
        row = (
            await session.execute(select(User).where(User.wechat_unionid == ws.unionid))
        ).scalar_one_or_none()
    return row


async def _locked_user(session: SessionDep, user_id: UUID) -> User:
    """与注销、改密、解绑共享用户锁，并刷新已加载的身份数据。"""
    return await auth_service.lock_user(session, user_id)


def _matches_identity(user: User, ws: WeChatSession) -> bool:
    return user.wechat_openid == ws.openid or bool(
        ws.unionid and user.wechat_unionid == ws.unionid
    )


# ---- A1: silent login --------------------------------------------------------


@router.post("/auth/wechat/login", response_model=ApiResponse[WeChatLoginResponse])
async def wechat_login(
    payload: WeChatLoginRequest,
    session: SessionDep,
    request: Request,
) -> ApiResponse[WeChatLoginResponse]:
    """Silent login from `wx.login()`.

    Bound → mints a session and returns the user, so the mini program can go
    straight to the home page with no input. Unbound → `bound=False`; the client
    shows the phone/password form and calls `/auth/wechat/bind`.
    """
    if not _wechat_ip_limiter.check(client_ip(request)):
        raise _too_many()

    ws = await wechat_service.code_to_session(payload.code)
    user = await _find_bound_user(session, ws)
    if user is None:
        return ok(WeChatLoginResponse(bound=False))

    user = await _locked_user(session, user.id)
    if user.deleted_at is not None or not user.password_hash or not _matches_identity(user, ws):
        return ok(WeChatLoginResponse(bound=False))

    token = await issue_session(
        session,
        user.id,
        ttl_days=settings.session_ttl_days,
        commit=False,
        client=CLIENT_MP,
    )
    await session.commit()
    return ok(WeChatLoginResponse(bound=True, user=UserRead.from_user(user), token=token))


# ---- A2: bind (login/register + bind in one shot) ----------------------------


@router.post("/auth/wechat/bind", response_model=ApiResponse[WeChatAuthResponse])
async def wechat_bind(
    payload: WeChatBindRequest,
    session: SessionDep,
    request: Request,
) -> ApiResponse[WeChatAuthResponse]:
    """Bind the caller's WeChat identity to a Wo account, logging in first.

    `phone` + `password` authenticate (or register) exactly like `/auth/login`;
    the resolved account then gets `wechat_openid` / `wechat_unionid` stamped on
    it and a mini-program session is minted.

    Idempotent on retry: if this WeChat identity is already bound and the
    supplied password matches that account, the existing account is returned
    instead of erroring. A password that doesn't match is a 409 — the caller
    should fall back to A1 rather than guessing further.
    """
    if not _wechat_ip_limiter.check(client_ip(request)):
        raise _too_many()

    ws = await wechat_service.code_to_session(payload.code)

    existing = await _find_bound_user(session, ws)
    if existing is not None:
        existing = await _locked_user(session, existing.id)
        auth_service.require_active_account(existing)
        if not _matches_identity(existing, ws):
            raise AppError(
                ErrorCode.WECHAT_OPENID_BOUND, "微信绑定状态已变化，请重试", status_code=409
            )
        if not existing.password_hash or not verify_password(
            payload.password, existing.password_hash
        ):
            raise AppError(
                ErrorCode.WECHAT_OPENID_BOUND,
                "该微信已绑定其他账号，请改用手机号登录",
                status_code=409,
            )
        user, is_new = existing, False
    else:
        user, is_new = await auth_service.login_or_register(
            session, payload.phone, payload.password
        )

    user = await _locked_user(session, user.id)
    auth_service.require_active_account(user)
    user.wechat_openid = ws.openid
    user.wechat_unionid = ws.unionid
    session.add(user)

    token = await issue_session(
        session,
        user.id,
        ttl_days=settings.session_ttl_days,
        commit=False,
        client=CLIENT_MP,
    )
    try:
        await session.commit()
    except IntegrityError as exc:
        # Concurrent bind of one WeChat identity to two accounts — the unique
        # constraint is the real guard; just report it cleanly.
        await session.rollback()
        raise AppError(
            ErrorCode.WECHAT_OPENID_BOUND,
            "该微信已绑定其他账号，请改用手机号登录",
            status_code=409,
        ) from exc
    await session.refresh(user)

    return ok(WeChatAuthResponse(user=UserRead.from_user(user), token=token, is_new=is_new))


# ---- A4 / A5: binding state ---------------------------------------------------


@router.get("/me/wechat", response_model=ApiResponse[WeChatBindingRead])
async def get_wechat_binding(
    session: SessionDep,
    current_user: CurrentUserDep,
) -> ApiResponse[WeChatBindingRead]:
    """Whether the current account is bound to a WeChat identity."""
    return ok(
        WeChatBindingRead(
            bound=current_user.wechat_openid is not None,
            has_unionid=current_user.wechat_unionid is not None,
        )
    )


@router.delete("/me/wechat", response_model=ApiResponse[dict])
async def unbind_wechat(
    session: SessionDep,
    current_user: CurrentUserDep,
    authorization: Annotated[str | None, Header(alias="Authorization")] = None,
) -> ApiResponse[dict]:
    """Unbind WeChat and drop the mini program's sessions.

    Refuses when the account has no password — unbinding would leave the user
    with no way back in. Rebinding later just means running A2 again.
    """
    token = parse_bearer(authorization)
    current_user = (
        await auth_service.locked_user(session, current_user.id, token)
        if token is not None else await _locked_user(session, current_user.id)
    )
    auth_service.require_active_account(current_user)
    if not current_user.password_hash:
        raise AppError(
            ErrorCode.VALIDATION_ERROR,
            "请先设置密码再解绑微信，否则将无法登录",
            status_code=400,
        )

    current_user.wechat_openid = None
    current_user.wechat_unionid = None
    session.add(current_user)
    # Unbinding should sign the mini program out: its tokens were only ever
    # obtainable through the WeChat identity we just dropped. The app's own
    # sessions are untouched.
    await session.execute(
        delete(AuthSession).where(
            AuthSession.user_id == current_user.id,
            AuthSession.client == CLIENT_MP,
        )
    )
    await session.commit()
    return ok({"unbound": True})
