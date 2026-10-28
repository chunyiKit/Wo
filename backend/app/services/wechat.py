"""WeChat Mini Program login — exchange a one-shot `wx.login()` code for identity.

The mini program calls `wx.login()` to get a short-lived `code`, ships it here,
and we trade it with WeChat's `jscode2session` for the stable identifiers:

- `openid`  — unique per (user × this mini program). Always returned.
- `unionid` — unique per (user × 微信开放平台账号). Only returned when the mini
              program is bound to an Open Platform account, which is our case,
              so it's the identifier to prefer when present.

We deliberately **do not persist `session_key`**. It is only needed to decrypt
encrypted user data (`getPhoneNumber`, encrypted `getUserInfo`) — capabilities
that require a 企业主体 and that this personal-subject mini program cannot use.
Not storing it means one less long-lived secret at rest. Revisit only if we
later add a decryption-backed flow.

References: https://developers.weixin.qq.com/miniprogram/dev/OpenApiDoc/
"""

from __future__ import annotations

from typing import Any

import httpx
from pydantic import BaseModel

from app.core.config import settings
from app.core.errors import AppError, ErrorCode

_JSCODE2SESSION_URL = "https://api.weixin.qq.com/sns/jscode2session"

# Upstream `errcode` → (our error code, user-facing message). WeChat returns
# `errcode: 0` (or omits it) on success. Anything unlisted falls back to
# WECHAT_UPSTREAM so a new upstream code can't leak raw WeChat wording.
_ERRCODE_MAP: dict[int, tuple[str, str]] = {
    40029: (ErrorCode.WECHAT_CODE_INVALID, "微信登录凭证无效或已过期，请重试"),
    40163: (ErrorCode.WECHAT_CODE_INVALID, "微信登录凭证已被使用，请重新登录"),
    45011: (ErrorCode.RATE_LIMIT, "微信登录过于频繁，请稍后再试"),
    40226: (ErrorCode.WECHAT_UPSTREAM, "微信登录被风控拦截，请稍后再试"),
    40013: (ErrorCode.WECHAT_NOT_CONFIGURED, "小程序 AppID 配置有误"),
    40125: (ErrorCode.WECHAT_NOT_CONFIGURED, "小程序 AppSecret 配置有误"),
}


class WeChatSession(BaseModel):
    """The identity WeChat vouched for. `openid` is always set; `unionid` only
    when the mini program is bound to an Open Platform account."""

    openid: str
    unionid: str | None = None


def _not_configured() -> AppError:
    return AppError(
        ErrorCode.WECHAT_NOT_CONFIGURED,
        "微信小程序未配置，请联系服务端设置 AppID / AppSecret",
        status_code=503,
    )


async def code_to_session(code: str) -> WeChatSession:
    """Exchange a `wx.login()` code for the caller's WeChat identity.

    Raises `AppError`:
    - WECHAT_NOT_CONFIGURED (503) when credentials are missing or wrong.
    - WECHAT_CODE_INVALID (401) when the code is stale / already consumed.
    - WECHAT_UPSTREAM (502) when WeChat is unreachable or returns an unknown
      error — the client should surface "微信登录失败，请重试".
    """
    code = (code or "").strip()
    if not code:
        raise AppError(ErrorCode.VALIDATION_ERROR, "缺少微信登录凭证", status_code=422)
    if not settings.wechat_app_id or not settings.wechat_app_secret:
        raise _not_configured()

    try:
        async with httpx.AsyncClient(timeout=settings.wechat_timeout_seconds) as client:
            res = await client.get(
                _JSCODE2SESSION_URL,
                params={
                    "appid": settings.wechat_app_id,
                    "secret": settings.wechat_app_secret,
                    "js_code": code,
                    "grant_type": "authorization_code",
                },
            )
    except httpx.HTTPError as exc:
        raise AppError(
            ErrorCode.WECHAT_UPSTREAM, "无法连接微信服务，请稍后重试", status_code=502
        ) from exc

    try:
        payload: dict[str, Any] = res.json()
    except ValueError as exc:
        raise AppError(
            ErrorCode.WECHAT_UPSTREAM, "微信服务返回了无法解析的内容", status_code=502
        ) from exc

    errcode = int(payload.get("errcode") or 0)
    if errcode != 0:
        mapped = _ERRCODE_MAP.get(errcode)
        if mapped is not None:
            code_name, message = mapped
            status = 401 if code_name == ErrorCode.WECHAT_CODE_INVALID else 502
            raise AppError(code_name, message, status_code=status, details={"errcode": errcode})
        raise AppError(
            ErrorCode.WECHAT_UPSTREAM,
            "微信登录失败，请稍后重试",
            status_code=502,
            details={"errcode": errcode},
        )

    openid = payload.get("openid")
    if not openid:
        raise AppError(ErrorCode.WECHAT_UPSTREAM, "微信服务未返回 openid", status_code=502)
    return WeChatSession(openid=openid, unionid=payload.get("unionid") or None)


__all__ = ["WeChatSession", "code_to_session"]
