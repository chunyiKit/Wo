"""账号注销：清空账号身份，保留家庭历史内容并匿名展示提交者。

回忆、留言、账目、聊天和附件不因作者注销而删除，原有可见范围不变。
users 行与历史外键保留，用于维持权限及幂等；插件中的身份快照单独匿名化。
注销者退出全部家庭，主理人自动移交；没有其他成员的家庭仍按现有规则解散。
个人头像在事务提交后删除，避免回滚时误删仍在使用的头像。
"""

from __future__ import annotations

import contextlib
from datetime import UTC, datetime
from uuid import uuid4

from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import AppError, ErrorCode
from app.core.password import verify_password
from app.core.storage import storage
from app.models.auth_session import AuthSession
from app.models.device_token import DeviceToken
from app.models.family import Family
from app.models.invitation import Invitation
from app.models.membership import Membership
from app.models.notification import Notification
from app.models.user import User
from app.plugins.registry import registry
from app.services import auth as auth_service
from app.services.family_storage import family_storage_keys
from app.services.membership import lock_family_memberships

# 已注销账号的统一展示名。刻意不带任何原昵称痕迹。
_ANON_NAME = "已注销用户"


async def delete_account(
    session: AsyncSession, user: User, password: str, *, token: str | None = None
) -> dict:
    """注销 `user`，返回结果统计。

    Raises:
        AppError 401: 密码不正确（挡住误触，以及会话被盗后的恶意注销）
        AppError 409: 已经注销过了
    """
    # ---- ① 身份校验 -------------------------------------------------------
    # 不可逆操作。只点一个确认框不够：拿到已登录手机的人就能把账号清掉，
    # 会话被盗后也能这么毁号。要求输入当前密码是零成本的（后端已有 hash）。
    # 先判「已注销」再校验密码：注销会清空 password_hash，若先校验密码，
    # 重复调用只会得到一个含义不清的 401，而不是「这个账号已经注销了」。
    user = (
        await auth_service.locked_user(session, user.id, token)
        if token is not None else await auth_service.lock_user(session, user.id)
    )
    if user.deleted_at is not None:
        raise AppError(ErrorCode.VALIDATION_ERROR, "该账号已注销", status_code=409)
    if not verify_password(password, user.password_hash):
        # 与 /auth/login 保持一致：密码错误统一走 UNAUTHORIZED + 401。
        raise AppError(ErrorCode.UNAUTHORIZED, "密码不正确", status_code=401)

    now = datetime.now(UTC)
    keys: list[str] = []

    # ---- ② 匿名化插件保存的身份快照，保留所有历史内容与附件 -----------------
    # 失败必须回滚，不能留下账号已注销、聊天昵称却尚未清除的半成品。
    for hook in registry.anonymize_user_hooks():
        await hook(session, user.id)

    # ---- ③ 头像对象 -------------------------------------------------------
    if user.avatar_storage_key:
        keys.append(user.avatar_storage_key)

    # ---- ④ 家庭：先把「主理人」身份交出去 ---------------------------------
    # 现有 leave_family 禁止 owner 直接离开 —— 注销也不能绕开这个问题：
    # 一注销，全家的数据就没了主人（没人能转移、没人能解散）。
    stats = await _settle_families(session, user)
    keys.extend(stats["storage_keys"])

    # ---- ⑤ 身份数据清空（匿名化） -----------------------------------------
    user.phone = None  # 释放手机号：这个号可以被重新注册
    user.password_hash = None  # 从此无法登录
    user.recovery_code_hash = None
    user.recovery_expires_at = None
    user.wechat_openid = None  # 释放微信绑定
    user.wechat_unionid = None
    user.avatar_storage_key = None
    user.avatar_content_type = None
    user.avatar_version = 0
    user.avatar_emoji = "👤"
    user.display_name = _ANON_NAME
    # 释放原 username（它有唯一约束，不释放这个号就再也不能被别人用了）。
    # 注意**不能**用 user.id 的前缀做新名字：项目用的是 UUIDv7，前 48 位是
    # 毫秒时间戳，同一时段创建的账号前缀几乎相同 —— 切前 8 位必撞唯一约束。
    # 直接用一枚全新的 uuid4 随机串，长度正好卡在 max_length=32 以内。
    user.username = f"deleted_{uuid4().hex[:24]}"
    user.current_family_id = None
    user.notification_prefs = {}
    user.deleted_at = now
    session.add(user)

    # ---- ⑥ 会话 / 推送设备 / 通知 / 邀请 -----------------------------------
    # 会话先删：这一步之后，所有端（App + 小程序）的 token 立刻失效。
    await session.execute(delete(AuthSession).where(AuthSession.user_id == user.id))
    await session.execute(delete(DeviceToken).where(DeviceToken.user_id == user.id))
    await session.execute(delete(Notification).where(Notification.user_id == user.id))
    # 他发出的邀请作废（否则别人还能拿着链接进一个没人管的家）；
    # 他用过的邀请保留记录但摘掉指向（外键是 SET NULL，硬删才会自动置空）。
    await session.execute(delete(Invitation).where(Invitation.inviter_id == user.id))
    await session.execute(
        update(Invitation)
        .where(Invitation.used_by_user_id == user.id)
        .values(used_by_user_id=None)
    )

    await session.commit()

    # ---- ⑦ 提交后才删存储对象 ---------------------------------------------
    # 幂等：删不存在的对象不报错。个别失败（网络/权限）不影响注销已完成，
    # 剩下的靠运维定期扫（key 有规律，可按前缀清理）。
    deleted_objects = 0
    for key in dict.fromkeys(keys):
        with contextlib.suppress(Exception):
            await storage.delete(key)
            deleted_objects += 1

    return {
        "deleted_at": now.isoformat(),
        "families_left": stats["left"],
        "ownerships_transferred": stats["transferred"],
        "families_dissolved": stats["dissolved"],
        "storage_objects_deleted": deleted_objects,
    }


async def _settle_families(session: AsyncSession, user: User) -> dict:
    """处理该用户在所有家庭里的成员关系。

    - 普通成员 / 管理员：直接退出
    - 主理人 + 还有其他成员：自动把主理人交给资历最老的活跃成员（admin 优先）
    - 主理人 + 独苗：解散家庭（删 Family 行，插件数据靠外键 CASCADE）

    返回统计，供端点回传给客户端（用户有权知道自己删掉了什么）。
    """
    family_ids = (
        await session.execute(
            select(Membership.family_id)
            .where(Membership.user_id == user.id)
            .order_by(Membership.family_id)
        )
    ).scalars().all()

    left = transferred = dissolved = 0
    keys: list[str] = []

    for family_id in family_ids:
        await lock_family_memberships(session, family_id)
        # 等待家庭锁时角色可能已移交，必须重新读取，不能使用 ORM 里的旧角色。
        m = (await session.execute(
            select(Membership).where(
                Membership.user_id == user.id, Membership.family_id == family_id,
                Membership.status == "active",
            ).execution_options(populate_existing=True)
        )).scalar_one_or_none()
        if m is None:
            continue
        others = (
            await session.execute(
                select(Membership)
                .where(
                    Membership.family_id == m.family_id,
                    Membership.user_id != user.id,
                    Membership.status == "active",
                )
                .order_by(Membership.joined_at)
                .execution_options(populate_existing=True)
            )
        ).scalars().all()

        if m.role == "owner":
            if others:
                # admin 优先，否则资历最老的成员
                heir = next((o for o in others if o.role == "admin"), others[0])
                await session.execute(
                    update(Membership)
                    .where(
                        Membership.family_id == m.family_id,
                        Membership.user_id == heir.user_id,
                    )
                    .values(role="owner")
                )
                transferred += 1
            else:
                # 无人接管的家庭仍按原有规则解散；有其他成员时始终保留家庭内容。
                keys.extend(await family_storage_keys(session, m.family_id))
                await session.execute(
                    delete(Membership).where(Membership.family_id == m.family_id)
                )
                await session.execute(delete(Family).where(Family.id == m.family_id))
                dissolved += 1
                continue

        await session.delete(m)
        left += 1

    await session.execute(delete(Membership).where(Membership.user_id == user.id))
    return {"left": left, "transferred": transferred, "dissolved": dissolved, "storage_keys": keys}
