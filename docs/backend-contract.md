# 「窝（Wo）」后端契约

> 给后端工程师对接用。包含产品定位、领域模型、API 形态、关键流程、权限矩阵。
> 后端栈：Python + FastAPI + PostgreSQL（见项目内存）。本文档与具体实现无关，
> 只定义契约。

---

## 1. 产品简介

「窝」是一款面向**年轻小家庭**（夫妻 / 情侣 / 三口之家）的**插件化**家庭事务 App。

核心特点：

- **家庭为单位**：所有功能围绕一个家庭运转，成员共享数据和能力。
- **插件化**：日程、记账、相册、清单、纪念日 …… 都是插件，按需启用。
- **多家庭**：一个账号可加入多个家庭（夫妻的窝、和爸妈的窝、朋友的窝），随时切换。
- **温暖而不工具感**：暖橙色调 + emoji 图标，避免「OA 系统」气质。

类比：**家庭版的 Notion + 微信小程序面板**。

---

## 2. 用户画像

- 25–35 岁年轻夫妻 / 情侣 / 小家庭
- 习惯使用 Notion、小红书、即刻、Things 等现代 App
- 重视生活仪式感和共同协作
- 对工具感强的 App 天然排斥

---

## 3. 核心概念模型

### 3.1 实体关系

```
User ─┬─ Membership ──┬─ Family ──┬─ InstalledPlugin ──┬─ PluginLayout
      │               │           │                    └─ PluginConfig
      │               │           ├─ Invitation
      │               └─ role     └─ FamilyPet
      │                              (角色 = pet 的"成员"特殊情况)
      └─ Notification
```

### 3.2 实体定义（一句话）

| 实体 | 定义 |
|------|------|
| **User** | 注册账号，对应一个自然人。一个 User 可以属于多个 Family。 |
| **Family** | 一个家庭，是数据隔离和协作的基本单位。有名称、emoji、标语。 |
| **Membership** | User × Family 的关联，记录角色（owner/admin/member/child/pet）和加入时间。 |
| **Plugin** | 插件市场上架的插件**定义**（一起看片、家庭相册等）。所有家庭共享。 |
| **InstalledPlugin** | 家庭已启用的插件**实例**，含布局、配置、安装人。 |
| **PluginLayout** | 插件在家庭首页栅格里的占位：`(col, row, cw, ch)`。 |
| **Invitation** | 邀请凭证（邀请码 / 链接 / 二维码扫码 token），有过期时间和指定角色。 |
| **Notification** | 推给用户的消息（家庭动态、插件提醒、邀请回执等）。 |

> **关于"宠物"**：当前设计把宠物当成一种 Membership 角色（`role=pet`），
> 而不是独立实体。这样宠物可以出现在成员列表、被 @、有自己的档案（由
> 宠物档案插件提供更多字段）。如果后续宠物需要复杂业务（疫苗记录、体重等），
> 由「宠物档案」插件本身的资源承担，不污染核心模型。

---

## 4. 全局约定

### 4.1 URL 结构

```
/api/v1/<resource>[/<id>[/<sub-resource>...]]
```

- **资源型 URL**，不动词化：`POST /families` 而不是 `/createFamily`。
- 家庭范围的资源用嵌套：`/families/{family_id}/plugins`、`/families/{family_id}/members`。
- 用户自身：`/me`、`/me/families`。

### 4.2 响应信封

所有响应统一信封（与项目 TS 规范一致）：

```jsonc
{
  "success": true,
  "data": { /* 资源数据 */ },
  "error": null,
  "meta": {                   // 分页时存在
    "total": 256,
    "cursor": "eyJpZCI6...",
    "limit": 20
  }
}
```

错误：

```jsonc
{
  "success": false,
  "data": null,
  "error": {
    "code": "FAMILY_NOT_FOUND",
    "message": "家庭不存在或已解散",
    "details": { "family_id": "abc" }
  }
}
```

### 4.3 鉴权

- **JWT Bearer Token**：`Authorization: Bearer <token>`。
- 不存 password — 走 SMS 验证码 / OAuth / Passkey 登录。
- Token 含 `user_id` + `current_family_id`（可被 `X-Family-Id` header 覆盖）。
- 切换家庭 = 改 `current_family_id`（写在 Refresh Token 里或单独的 session API）。

### 4.4 类型约定

| 字段 | 类型 | 备注 |
|------|------|------|
| ID | `string`（UUIDv7 或 ULID） | 客户端可生成，便于离线创建 |
| 时间 | ISO 8601 UTC：`2026-05-22T14:30:00Z` | 客户端按时区显示 |
| Emoji | `string`，限定 Unicode emoji 字符 | 不存 SVG / 图片 |
| 颜色 | 不在后端存（由设计 token 决定），仅返回分类标签 | |

### 4.5 分页

游标式：`GET /resource?cursor=<opaque>&limit=20`。后端控制 cursor 实现细节。

### 4.6 错误码（推荐）

| code | HTTP | 含义 |
|------|------|------|
| `UNAUTHORIZED` | 401 | 未登录 / token 失效 |
| `FORBIDDEN` | 403 | 已登录但无权限（角色不够） |
| `NOT_FOUND` | 404 | 资源不存在 |
| `FAMILY_NOT_FOUND` | 404 | 家庭不存在 |
| `INVITATION_EXPIRED` | 410 | 邀请码已过期 |
| `INVITATION_INVALID` | 400 | 邀请码格式错或已使用 |
| `PLUGIN_ALREADY_INSTALLED` | 409 | 该插件已装到该家庭 |
| `LAYOUT_CONFLICT` | 409 | 卡片位置冲突 |
| `RATE_LIMIT` | 429 | 限流 |
| `INTERNAL` | 500 | 服务器错误 |

---

## 5. 资源 & API

### 5.1 Auth & Me

| Method | Path | 说明 |
|--------|------|------|
| `POST` | `/auth/login/sms` | 发送验证码 |
| `POST` | `/auth/login/verify` | 校验验证码，发 access + refresh token |
| `POST` | `/auth/refresh` | 用 refresh token 换新 access token |
| `POST` | `/auth/logout` | 失效当前 refresh token |
| `GET` | `/me` | 当前用户信息 + 当前家庭 |
| `PATCH` | `/me` | 改名 / 头像 emoji |

```jsonc
// GET /me 响应
{
  "user": {
    "id": "01JBQ...",
    "username": "wo_chen_2024",
    "display_name": "老陈",
    "avatar_emoji": "👨",
    "level": 3,
    "created_at": "2024-03-15T08:21:00Z"
  },
  "current_family": { /* Family 对象，见 5.2 */ },
  "stats": {                  // 个人统计
    "families_joined": 2,
    "plugins_used": 7,
    "days_active": 423
  }
}
```

### 5.2 Family

| Method | Path | 说明 | 权限 |
|--------|------|------|------|
| `GET` | `/me/families` | 当前用户加入的所有家庭 | 自己 |
| `POST` | `/families` | 创建新家（创建者自动 = Owner） | 登录 |
| `GET` | `/families/{id}` | 家庭详情 | 成员 |
| `PATCH` | `/families/{id}` | 改名 / 改标语 / 改 emoji | Admin+ |
| `POST` | `/families/{id}/leave` | 主动离开（Owner 不能离开，需先转让） | 成员 |
| `DELETE` | `/families/{id}` | 解散家庭（不可逆） | Owner |
| `POST` | `/families/{id}/switch` | 把这个家庭设为当前 | 成员 |

```jsonc
// Family 对象
{
  "id": "01JBR...",
  "name": "老陈和小林的窝",
  "slogan": "一起住一起吃",
  "emoji": "🏡",
  "created_at": "2024-03-15T08:21:00Z",
  "member_count": 3,
  "my_role": "owner",
  "my_unread_count": 0
}
```

### 5.3 Membership

| Method | Path | 说明 | 权限 |
|--------|------|------|------|
| `GET` | `/families/{id}/members` | 成员列表（含 pending） | 成员 |
| `PATCH` | `/families/{id}/members/{user_id}` | 改角色 | Owner / Admin |
| `DELETE` | `/families/{id}/members/{user_id}` | 踢出 | Owner / Admin |
| `POST` | `/families/{id}/transfer-ownership` | 转让 Owner | Owner |

```jsonc
// Membership 对象
{
  "user_id": "01JBQ...",
  "family_id": "01JBR...",
  "role": "owner",            // owner | admin | member | child | pet
  "display_name": "老陈",      // 在该家庭里的昵称（可能覆盖 user.display_name）
  "avatar_emoji": "👨",
  "joined_at": "2024-03-15T08:21:00Z",
  "status": "active"          // active | pending（被邀请未接受）
}
```

### 5.4 Invitation

| Method | Path | 说明 | 权限 |
|--------|------|------|------|
| `POST` | `/families/{id}/invitations` | 生成邀请（返回 code + qr_payload + link） | Admin+ |
| `DELETE` | `/families/{id}/invitations/{code}` | 撤销 | Admin+ |
| `GET` | `/invitations/{code}/preview` | 预览（不接受，仅看家庭名/邀请人） | 公开 |
| `POST` | `/invitations/{code}/accept` | 接受邀请加入 | 登录 |

```jsonc
// POST /families/{id}/invitations 请求
{
  "role": "member",            // 默认 member，可指定 child/pet
  "ttl_seconds": 600,          // 10 分钟（面对面）/ 7 天（链接）
  "channel": "qr"              // qr | link | code
}

// 响应
{
  "code": "WO-W4M9-P2KX",
  "link": "https://wo.app/join/W4M9P2KX",
  "qr_payload": "wo://join?c=W4M9P2KX",
  "expires_at": "2026-05-22T15:00:00Z"
}
```

### 5.5 Plugin Marketplace

| Method | Path | 说明 | 权限 |
|--------|------|------|------|
| `GET` | `/plugins` | 浏览 / 搜索 / 分类筛选 | 公开 |
| `GET` | `/plugins/{plugin_id}` | 详情（含截图、权限、评分） | 公开 |
| `GET` | `/plugins/featured` | 精选推荐位 | 公开 |

```
GET /plugins?category=life&q=相册&cursor=...&limit=20
```

```jsonc
// Plugin 对象
{
  "id": "photo",                     // 短字符串 id，全局唯一，对应代码模块
  "name": "家庭相册",
  "description_short": "一起记录家的日常",
  "description_long": "...",
  "emoji": "📷",
  "category": "life",                // life | finance | health | education | entertainment
  "version": "1.4.2",
  "size_kb": 8420,
  "rating": 4.8,
  "install_count": 11320,
  "screenshots": [
    "https://cdn.wo.app/plugins/photo/screen-1.png"
  ],
  "permissions": [
    { "code": "members.read", "label": "读取家庭成员列表" },
    { "code": "notify.send", "label": "发送家庭通知" }
  ],
  "publisher": "Wo Studio",
  "published_at": "2025-11-20T00:00:00Z"
}
```

### 5.6 Installed Plugin（家庭已启用插件 + 布局）

| Method | Path | 说明 | 权限 |
|--------|------|------|------|
| `GET` | `/families/{id}/plugins` | 该家庭已启用的插件列表 + 布局 | 成员 |
| `POST` | `/families/{id}/plugins` | 安装插件到家庭 | Admin+ |
| `PATCH` | `/families/{id}/plugins/{install_id}` | 改布局 / 改设置 / enable/disable | Admin+ |
| `DELETE` | `/families/{id}/plugins/{install_id}` | 卸载 | Owner / Admin |
| `PUT` | `/families/{id}/layout` | 批量提交首页布局（拖拽编辑保存） | Admin+ |

```jsonc
// InstalledPlugin 对象
{
  "id": "01JBS...",                  // installation id
  "family_id": "01JBR...",
  "plugin_id": "photo",
  "plugin": { /* 嵌入 Plugin 对象快照 */ },
  "enabled": true,
  "layout": { "col": 0, "row": 0, "cw": 4, "ch": 2 },
  "config": { /* 插件自定义，jsonb */ },
  "preview": {                       // 首页卡片要展示的预览数据（由插件后端填充）
    "primary": "本周新照片 · 24",
    "secondary": "小林 · 2 分钟前",
    "badge": null,
    "color_token": "photo"           // 让前端按设计 token 上色：photo / money / anniv / chore / pet / accent
  },
  "installed_at": "2024-03-16T10:00:00Z",
  "installed_by": "01JBQ..."
}
```

**布局约束**（后端要校验）：

- `cw ∈ {1, 2, 4}`（也允许 3，但 UI 当前不出 3）
- `ch ∈ [1, 4]`
- `col + cw ≤ 4`（不能跨右边界）
- 同一家庭内不允许 cell 重叠
- `PUT /families/{id}/layout` 是事务性整体提交，失败回滚

```jsonc
// PUT /families/{id}/layout 请求
{
  "items": [
    { "install_id": "01JBS-photo", "col": 0, "row": 0, "cw": 4, "ch": 2 },
    { "install_id": "01JBS-anniv", "col": 0, "row": 2, "cw": 2, "ch": 2 },
    { "install_id": "01JBS-money", "col": 2, "row": 2, "cw": 2, "ch": 2 },
    ...
  ]
}
```

### 5.7 Plugin Content（每个插件自己的资源）

每个插件**独立路由空间**，URL 命名空间 = `/families/{id}/plugins/{plugin_id}/...`。
插件后端可以是同一服务，也可以是独立微服务，但对客户端是统一的。

```
/families/{id}/plugins/photo/albums
/families/{id}/plugins/photo/photos
/families/{id}/plugins/money/entries
/families/{id}/plugins/money/budgets
/families/{id}/plugins/anniversary/dates
/families/{id}/plugins/chore/tasks
/families/{id}/plugins/chore/assignments
/families/{id}/plugins/pet/profiles
/families/{id}/plugins/cinema/wishlist
/families/{id}/plugins/cinema/watched
```

> 每个插件的 schema 由各自的 Spec 单独写。这里只规范"挂载点"。

### 5.8 Notification

| Method | Path | 说明 |
|--------|------|------|
| `GET` | `/notifications` | 我的消息列表（分页） |
| `PATCH` | `/notifications/{id}/read` | 标记已读 |
| `POST` | `/notifications/read-all` | 全部已读 |

```jsonc
// Notification 对象
{
  "id": "01JBT...",
  "type": "member_joined",          // member_joined | plugin_event | invitation_accepted | ...
  "family_id": "01JBR...",
  "title": "小林加入了「老陈和小林的窝」",
  "body": "现在你们可以一起记录生活了 🎉",
  "icon_emoji": "👋",
  "deeplink": "wo://family/01JBR/members",
  "read_at": null,
  "created_at": "2026-05-22T14:00:00Z"
}
```

---

## 6. 关键流程

### 6.1 启动加载（First Frame Ready）

为了首页一次加载就显示完整，**bootstrap 接口**返回首屏所需全部数据：

```
GET /me/bootstrap
```

```jsonc
{
  "user": { ... },                  // 同 /me
  "current_family": { ... },
  "families": [ ... ],              // 我加入的所有家庭（用于切换）
  "installed_plugins": [ ... ],     // 当前家庭的插件 + 布局 + preview
  "unread_count": 3
}
```

客户端启动只发**一个**请求就能渲染首页（含所有卡片预览）。

### 6.2 加入家庭

```
1. 扫码 / 输入邀请码 → 客户端拿到 code
2. GET  /invitations/{code}/preview     → 显示"加入 XX 家"确认页
3. POST /invitations/{code}/accept      → 后端：
     a. 校验 code 有效 + 未过期 + 未使用
     b. 创建 Membership（role = invitation.role，默认 member）
     c. 标记 invitation used
     d. 给 Owner/Admin 发 Notification
     e. 返回新 Family
4. 客户端 POST /families/{new_family_id}/switch 切到新家
5. 客户端拉 /me/bootstrap 刷新首屏
```

### 6.3 创建新家

```
POST /families
{
  "name": "回老家",
  "slogan": "和爸妈的窝",
  "emoji": "👵"
}
→ 后端创建 Family + Owner Membership，返回 Family.id
→ 客户端自动 switch 到新家庭并 bootstrap
```

### 6.4 安装插件

```
1. 用户在市场点"安装"
2. POST /families/{id}/plugins  { "plugin_id": "photo" }
3. 后端：
   a. 校验家庭无重复安装
   b. 找一个空 cell 自动放置（first-fit），默认 cw/ch 由 Plugin.default_size 给
   c. 创建 InstalledPlugin
   d. 返回安装后的 InstalledPlugin（含 layout 与 preview）
4. 客户端就地把卡片插入首页栅格（无需重拉 bootstrap）
```

### 6.5 调整布局（长按编辑态保存）

```
1. 用户进入编辑态，拖拽卡片重排
2. 用户点"完成" → 客户端构建完整布局数组
3. PUT /families/{id}/layout  { "items": [ ... ] }
4. 后端事务性校验 + 写入；冲突返回 LAYOUT_CONFLICT
```

### 6.6 卸载插件

```
DELETE /families/{id}/plugins/{install_id}
→ 后端：删 InstalledPlugin（cascade 删 PluginContent，或保留为只读历史，取决于插件）
→ 客户端从栅格移除卡片
```

---

## 7. 权限矩阵

| 操作 | Owner | Admin | Member | Child | Pet |
|------|:-----:|:-----:|:------:|:-----:|:---:|
| 浏览家庭内容 | ✅ | ✅ | ✅ | ✅ | n/a |
| 邀请新成员 | ✅ | ✅ | ❌ | ❌ | — |
| 改家庭名 / 标语 / emoji | ✅ | ✅ | ❌ | ❌ | — |
| 改其他成员角色 | ✅ | ⚠️ 只能改 ≤ 自己等级 | ❌ | ❌ | — |
| 踢出成员 | ✅ | ✅（除 Owner） | ❌ | ❌ | — |
| 安装插件 | ✅ | ✅ | ❌ | ❌ | — |
| 卸载插件 | ✅ | ✅ | ❌ | ❌ | — |
| 调整首页布局 | ✅ | ✅ | ❌ | ❌ | — |
| 转让 Owner | ✅ | ❌ | ❌ | ❌ | — |
| 解散家庭 | ✅ | ❌ | ❌ | ❌ | — |

> Pet 是名义角色，对应的"用户"通常是 Owner 代建的占位账号，没有真实登录能力。
> Child 可以登录，但只读家庭设置。

各插件的细粒度权限由插件自己的 Spec 定义（如"记账只允许自己 / 自己+Admin 编辑"）。

---

## 8. 数据隔离原则

- **跨家庭零泄漏**：任意业务接口必须校验 `(user, family)` 关系。
- 即便客户端传错 `family_id`，后端必须返回 `FORBIDDEN` 而不是 200。
- 推荐：所有 family-scope 资源在数据库层加 `family_id` 列 + 强制索引 + Row-Level Security（PG 提供）。

---

## 9. 未来扩展（埋点）

下面这些**尚未在 v1 实现**，但 schema 应预留兼容空间：

- **Family Pets 独立资源**：当前 pet 是角色；若未来宠物档案插件做大，考虑独立 `pets` 资源。
- **跨家庭分享**：A 家庭把某张相片分享到 B 家庭——预留 `share_token`。
- **插件订阅 / 付费**：Plugin 加 `pricing` 字段（free / one-time / subscription）。
- **多端同步**：客户端写操作带 `client_op_id`，幂等去重。
- **审计日志**：高敏操作（踢人、解散家庭、转让 Owner）写 `audit_log` 表。
- **i18n**：所有人面消息（Notification.title/body）支持 `locale` 后端模板渲染。

---

## 10. 与前端 Flutter 工程的对应

| 前端 Feature | 主要消费的资源 |
|--------------|---------------|
| `splash` | `GET /me/bootstrap` |
| `onboarding` | 纯本地 |
| `join` | `/invitations/{code}/preview`、`/invitations/{code}/accept`、`/families` (POST) |
| `home` | `/families/{id}/plugins`（含布局 + preview）、`PUT /families/{id}/layout` |
| `marketplace` | `/plugins`、`/plugins/{id}`、`POST /families/{id}/plugins` |
| `family` | `/families/{id}`、`/families/{id}/members`、`/families/{id}/invitations` |
| `profile` | `/me`、`/me/families`、`/families/{id}/switch` |
| `messages` | `/notifications` |

---

## 附录 A · pydantic schema 草案

```python
# app/schemas.py
from __future__ import annotations
from datetime import datetime
from typing import Literal
from uuid import UUID
from pydantic import BaseModel, Field

Role = Literal["owner", "admin", "member", "child", "pet"]
PluginCategory = Literal["life", "finance", "health", "education", "entertainment"]


class ApiResponse(BaseModel):
    success: bool
    data: dict | None = None
    error: ApiError | None = None
    meta: Meta | None = None


class ApiError(BaseModel):
    code: str
    message: str
    details: dict | None = None


class Meta(BaseModel):
    total: int | None = None
    cursor: str | None = None
    limit: int | None = None


class User(BaseModel):
    id: UUID
    username: str
    display_name: str
    avatar_emoji: str
    level: int = 1
    created_at: datetime


class Family(BaseModel):
    id: UUID
    name: str = Field(max_length=16)
    slogan: str | None = Field(default=None, max_length=24)
    emoji: str
    created_at: datetime
    member_count: int
    my_role: Role
    my_unread_count: int = 0


class Membership(BaseModel):
    user_id: UUID
    family_id: UUID
    role: Role
    display_name: str
    avatar_emoji: str
    joined_at: datetime
    status: Literal["active", "pending"]


class PluginLayout(BaseModel):
    col: int = Field(ge=0, le=3)
    row: int = Field(ge=0)
    cw: Literal[1, 2, 3, 4]
    ch: int = Field(ge=1, le=4)


class PluginPreview(BaseModel):
    primary: str
    secondary: str | None = None
    badge: str | None = None
    color_token: Literal["photo", "money", "anniv", "chore", "pet", "accent"]


class Plugin(BaseModel):
    id: str
    name: str
    description_short: str
    description_long: str
    emoji: str
    category: PluginCategory
    version: str
    size_kb: int
    rating: float
    install_count: int
    screenshots: list[str]
    permissions: list[Permission]
    publisher: str
    published_at: datetime


class Permission(BaseModel):
    code: str
    label: str


class InstalledPlugin(BaseModel):
    id: UUID
    family_id: UUID
    plugin_id: str
    plugin: Plugin
    enabled: bool
    layout: PluginLayout
    config: dict
    preview: PluginPreview
    installed_at: datetime
    installed_by: UUID


class Invitation(BaseModel):
    code: str
    family_id: UUID
    inviter_id: UUID
    role: Role
    channel: Literal["qr", "link", "code"]
    expires_at: datetime
    used_at: datetime | None = None


class Notification(BaseModel):
    id: UUID
    type: str
    family_id: UUID | None
    title: str
    body: str
    icon_emoji: str
    deeplink: str | None
    read_at: datetime | None
    created_at: datetime


class Bootstrap(BaseModel):
    """启动一次性接口，前端首屏渲染所需的全部数据。"""
    user: User
    current_family: Family
    families: list[Family]
    installed_plugins: list[InstalledPlugin]
    unread_count: int
```

---

## 文档版本

- v0.1 — 2026-05-22 — 首次起草，覆盖 v1 范围（首页 + 加入/创建 + 市场 + 家庭管理 + 我的）。
