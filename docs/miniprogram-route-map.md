# 微信小程序配套 · Route Map（可拆分方案）

> 目标：为 Wo（Android）做一个配套微信小程序，**账号互通 + 数据互通**。
> 以「回忆」插件作为第一个打通全链路的插件，跑通后再按插件逐个接入。
>
> **进度：P0 账号互通底座 + P1 壳与插件路由（含首页记忆卡封面）+ P2 回忆·读 +
> P3 回忆·写 + P4 的 D2/D3（COS 直传）+ 账号注销（提审合规）已实现**，均已部署
> 到生产（域名 `wo.chunyi-work.online` + Let's Encrypt）。
> 至此「回忆插件打通全链路」的定义（能看能写）已达成，上传也不再经 CVM 中转；
> P4 其余项（分享卡片、订阅消息、第二个插件分包）仍是设计。
> 已落地内容见 §4.1–§4.5；小程序侧的搭建与发布前检查见 `miniprogram/README.md`。
>
> ⚠️ **发布前还差一项**：COS 域名
> `https://wo-app-1258101097.cos.ap-shanghai.myqcloud.com` 必须加进小程序后台的
> **downloadFile 合法域名**。只加后端域名的话接口正常、图片全白。

---

## 一、现状盘点（读代码得出）

### 1.1 后端

| 维度 | 现状 | 对小程序的影响 |
|---|---|---|
| 框架 | FastAPI，统一前缀 `/api/v1`，信封 `{success, data, meta, error}` | 可复用，小程序侧照抄 `ApiClient._sendEnvelope` 的拆封逻辑 |
| 鉴权 | 不透明 Bearer token，`secrets.token_urlsafe(32)`，仅存 SHA-256，`auth_sessions` 表，TTL 90 天 | ✅ 可直接给小程序用（存 `wx.setStorageSync`） |
| 登录入口 | `POST /auth/login`，`{phone, password}`，**`login_or_register`（不存在就自动注册）** | ⚠️ 小程序不能沿用"自动注册"，会造垃圾账号 |
| 微信能力 | **完全没有**（全仓 grep `wechat/weixin/openid/appid` 零命中） | 全绿野，需新增 |
| 数据隔离 | `require_membership(session, user_id, family_id)`，非成员一律 404 | ✅ 照搬即可，无需改造 |
| 插件架构 | `registry`（manifest + router + preview hook）；插件路由 `/families/{fid}/plugins/{plugin_id}/...` | ✅ 小程序可复用同一套"插件注册表"心智 |
| 分页 | keyset 游标（base64 不透明），`meta:{total,cursor,limit}` | ✅ 小程序触底加载天然适配 |
| 图片 | `/raw` 端点 **302 跳转到 COS 预签名 URL**（1h TTL） | ⚠️ 见 1.3，这是最大的适配点 |
| 聚合首屏 | `GET /me/bootstrap` → user + current_family + families + installed_plugins + unread_count | ✅ 小程序首屏一请求搞定 |

已注册插件 **16 个**：accounting / anniversary / calendar / chat / chore / expiry / memory / movie / pet / photo / plant / recipe / retirement / stock / subscription / travel。

### 1.2 回忆插件现有路由（`backend/app/plugins/memory/routes.py`）

```
GET    /families/{fid}/plugins/memory/memories                      时间线（游标分页）
POST   /families/{fid}/plugins/memory/memories                      新建（支持 client_id 幂等）
GET    /families/{fid}/plugins/memory/memories/{mid}                 详情（含媒体+留言）
PUT    /families/{fid}/plugins/memory/memories/{mid}                 更新
DELETE /families/{fid}/plugins/memory/memories/{mid}                 删除
POST   /families/{fid}/plugins/memory/memories/{mid}/media           上传（multipart，client_id 幂等）
DELETE /families/{fid}/plugins/memory/memories/{mid}/media/{id}      删除媒体
GET    /families/{fid}/plugins/memory/memories/{mid}/media/{id}/raw   原图（302→COS）
POST   /families/{fid}/plugins/memory/memories/{mid}/comments         留言
DELETE /families/{fid}/plugins/memory/memories/{mid}/comments/{cid}   删留言
```

**结论：这 10 个端点一个都不用改，小程序直接调。** 数据互通在数据层是"免费的"——
同一个库、同一套鉴权、同一套隔离规则。真正的工作量在**账号打通**和**图片加载**两处。

### 1.0 已确认的前提（用户提供的信息）

| 项 | 值 |
|---|---|
| 小程序 AppID | `wx0619d005f568430c` |
| AppSecret | 放 `backend/.env` / 线上 `/etc/wo/app.env`（已 gitignore） |
| 域名 | `wo.chunyi-work.online`（已备案，指向后端服务器，**尚未配 HTTPS**） |
| 主体 | **个人** → 无 `getPhoneNumber` 权限，一键取手机号不可用 |
| 首登策略 | **A** 手机号 + 密码登录后绑定 |
| 微信开放平台 | 已绑定 → `jscode2session` 能返回 `unionid` |
| 开放平台 SDK | App 端未接入 → P4 的 App↔小程序互跳不做 |

### 1.3 三个必须在设计阶段解决的硬约束

> **① 小程序 `<image>` 组件不能带自定义请求头。**
> 现有 `/raw` 依赖 `Authorization: Bearer`，小程序拿不到字节。而它 302 到 COS 后，
> 最终域名还要在小程序后台的 `downloadFile` 白名单里，且 `<image>` 跟随 302 的行为不可控。
> → **必须新增"换直链"端点**（见 C1–C4），返回 `{url, expires_at}`，前端再喂给 `<image>`。

> **② `resolve_user_id` 会踢掉"无密码"用户。**
> `app/services/session.py` 里解析 token 时 join 了 `User.password_hash.is_not(None)` 和
> `!= ""`。纯微信注册的用户若没设密码，**每次请求都会 401**，表现为"登录成功但立刻掉线"。
> → P0 必须处理：要么放宽该条件（加 `client` 维度区分），要么强制微信用户设密码。

> **③ 域名白名单与备案。**
> 小程序 request / uploadFile / downloadFile 三类域名都需在微信后台登记，且必须 HTTPS + 已备案。
> 除 API 域名外，**COS 域名也要登记**（若走 C1 直链方案则必须）。
> → 属于"开工前必须拿到的东西"，不是代码问题。

---

## 二、新增后端路由表（按能力分层）

### A. 账号互通（新增）

| # | Method | Path | 说明 | Phase |
|---|---|---|---|---|
| A1 | POST | `/api/v1/auth/wechat/login` | `{code}` → 后端用 appid/secret 换 `jscode2session` 得 openid/unionid。已绑定 → 签发 token 返回 `{user, token}`；未绑定 → `{bound:false, ticket}` | P0 |
| A2 | POST | `/api/v1/auth/wechat/bind` | 带 Bearer（手机号密码已登录）→ `{code}` → 绑定 openid 到当前用户 | P0 |
| A3 | POST | `/api/v1/auth/wechat/register` | `{code, phone, password, display_name?}` → 新注册 + 绑定 | P0 |
| A4 | GET | `/api/v1/me/wechat` | 当前用户微信绑定状态 | P0 |
| A5 | DELETE | `/api/v1/me/wechat` | 解绑（须保留手机/密码任一登录因子） | P0 |
| A6 | POST | `/api/v1/auth/wechat/bind-ticket` | App 端已登录态申请一次性绑定码 → `{ticket, expires_at}`（配合 App 内展示二维码） | P4 |
| A7 | POST | `/api/v1/auth/wechat/redeem-ticket` | 小程序侧 `{code, ticket}` 兑换绑定 | P4 |
| A8 | POST | `/api/v1/me/delete-account` | `{password}` → 永久注销（见 §4.5） | 提审合规 ✅ |

配套改动（非新路由）：
- 新增绑定表或 `users` 加列：`wechat_openid` / `wechat_unionid`（unionid 打通同一主体多端）。
- `auth_sessions` 加 `client` 列（app / mp），便于分端查看与单独吊销。
- 修 `resolve_user_id` 的 `password_hash` 条件（见 §1.3 ②）。

### B. 媒体访问（新增，解决 §1.3 ①）—— **P2 已落地**

| # | Method | Path | 说明 | 状态 |
|---|---|---|---|---|
| C1 | POST | `.../memory/media/urls` | 批量换回忆媒体直链 → `{urls:{id:url}, expires_at}` | ✅ 已实现 |
| C2 | GET | `/api/v1/families/{fid}/members/{uid}/avatar-url` | 成员头像直链 | ✅ 已实现 |
| C3 | GET | `/api/v1/me/avatar-url` | 自己头像直链 | ✅ 已实现 |
| C4 | GET | `/api/v1/families/{fid}/background-url` | 家庭背景直链 | ❌ **不需要** —— `Family` 模型没有背景图字段 |

**与原设计的三处偏离，都有原因**：

1. **C1 做成批量而非单个**。原设计是「每张图一个请求」，但一页时间线是
   20 条回忆 × 平均 6 张图 ≈ 120 个 URL —— 那会直接打满小程序请求并发。
   改成一次 POST 传 `media_ids[]`，一个往返换完全页。
2. **C4 取消**。`Family` 表里没有背景图字段，是我原设计时的臆测。
3. **存储不支持预签名时明确 501**（`STORAGE_NO_DIRECT_URL`），而不是返回一个
   注定会 401 的 URL —— 客户端据此降级成占位图，而不是显示一片空白。

**线上已验证**（真实 COS 对象，**不带任何请求头**）：
`GET <签名URL>` → 200 / `image/jpeg` / 699 KB / 1600×2133；
去掉签名参数 → 403（证明对象确实是 private，签名是必需的）。

> `PluginPreview.image_urls`（首页卡片轮播图）与 C1 同源。P1 没渲染它，后来首页
> 补齐：从这些 `/raw` 地址里解析出 media id，复用 `utils/media-url.js` 换直链。

### D. 上传（P3 先复用，P4 可选增强）

| # | Method | Path | 说明 | Phase |
|---|---|---|---|---|
| D1 | — | 复用 `POST .../media` | `wx.uploadFile` **支持自定义 header**，Bearer + multipart 可直接用 | P3 ✅ 已落地 |
| D2 | POST | `.../media/presign` | 返回 COS 直传票据（PostObject 签名策略） | P4 ✅ 已落地 |
| D3 | POST | `.../media/commit` | 直传完成后落库 | P4 ✅ 已落地 |

P3 用 D1，**后端一行未改**（✅ 已实现，见 4.4）；视频上限 `memory_video_max_bytes = 100MB`，
前端在 `wx.chooseMedia` 之后就会按 20MB（照片）/ 100MB（视频）预先拦掉超限文件，
不让用户等两分钟换来一个 413。

**D2/D3 已实现并部署**（2026-10-28），小程序现在是「先直传、失败回退中转」：

- **D2 只签票、不落任何状态**。票据是一段签过名的策略（POST Object policy），
  里面钉死了四个条件：只能写这个 key、只能是这个 Content-Type、ACL 必须是
  `private`、大小必须在 `content-length-range` 之内。SecretKey 从不离开服务端。
  所以票据本身无状态 —— 幂等性全部放在 D3（按 `media_id` 判重）。
- **D3 做三件校验**替代「服务端看字节」：① `key` 必须等于这个 `media_id` 当初
  签发的那个（否则可以拿别人的票据落库）；② 对象存在且不超过同一个上限；
  ③ 前 16 个字节的魔数不能和声明的 kind 矛盾（比如声明照片却是 `ftyp`）。
- **两条路的取舍**：直传省掉 CVM 的一次上行带宽，但放弃了服务端的完整解码校验
  （Pillow `verify()`）。小程序是唯一走直传的客户端，App 仍然走 D1 —— 这条不对等
  是刻意的，等直传在真机上跑稳再说。
- **直传不是唯一通路**：票据过期、COS 域名没进 uploadFile 白名单、弱网中断、
  部署本身不支持直传（本地磁盘），任何一种情况都会静默回退到 D1，用户无感。

**部署后已完成**：`https://wo-app-1258101097.cos.ap-shanghai.myqcloud.com`
已加进微信后台的 **uploadFile 合法域名**（与 downloadFile 是两张名单，都要有）。
至此上传、下载、接口三类域名齐备，发布前清单无待办。

### E. 完全复用、无需改动的端点

```
POST /api/v1/auth/login · /auth/logout · /auth/change-password · /auth/reset-password
GET  /api/v1/me/bootstrap          ← 小程序首屏
GET  /api/v1/me  ·  PATCH /api/v1/me
GET  /api/v1/families/{fid}/plugins
POST /api/v1/families/{fid}/switch
GET  /api/v1/families/{fid}/members
回忆插件全部 10 条路由
```

---

## 三、小程序页面路由 + 分包规划

### 主包（目标 < 1.5MB）

| 路径 | 说明 |
|---|---|
| `pages/index/index` | 启动引导：`wx.login` 静默换 token；未绑定 → 跳 bind |
| `pages/auth/bind` | 绑定 / 注册（手机号+密码，或 ticket 兑换） |
| `pages/home/home` | Tab · 家庭卡片墙（读 `installed_plugins` + preview） |
| `pages/me/me` | Tab · 我的（头像、微信绑定状态、切换/创建家庭、设置） |
| `pages/family/switch` | 家庭列表与切换 |

### 分包 `package-memory`（回忆）

| 路径 | 说明 |
|---|---|
| `pages/timeline/timeline` | 时间线（按月分组、游标触底加载） |
| `pages/detail/detail?id=` | 详情（媒体 + 留言） |
| `pages/edit/edit?id=` | 新建 / 编辑（`id` 空为新建） |
| `pages/gallery/gallery?id=&index=` | 大图 / 视频浏览 |

`app.json` 配 `preloadRule`：进入 `pages/home/home` 时预下载 `package-memory`。
后续每个插件一个分包，主包只承担"账号 + 壳 + 注册表"。

### 小程序端服务层（`utils/`、`services/`）

```
utils/request.js     Bearer 注入 + 拆信封 + 401 自动重登（对齐 ApiClient）
utils/auth.js        wx.login → code → /auth/wechat/login；token 持久化
utils/media.js       直链解析 + 本地缓存（按 expires_at 提前 5 分钟刷新）
services/plugin-registry.js   {pluginId → {name, emoji, package, page}}  ← 小程序侧"插件注册表"
services/memory.js   回忆插件接口
```

`plugin-registry.js` 是后端 `registry` 在小程序侧的镜像，负责"卡片点哪里"。
新增插件 = 加一个分包 + 注册表加一行，**主包不动**。

> 沿用 AGENTS.md 的两条交互约束：
> 列表刷新要"就地替换"不能闪（`setData` 增量，不要整页换 loading）；
> 展示成员处要接真实头像、无头像才回退 emoji。

---

## 四、拆分方案（P0 → P4，每期可独立发版 / 回滚）

### 4.1 P0 账号互通底座 —— 已实现 ✅

**后端**

| 文件 | 内容 |
|---|---|
| `app/core/config.py` | `wechat_app_id` / `wechat_app_secret` / `wechat_timeout_seconds` |
| `app/core/errors.py` | 新增 `WECHAT_NOT_CONFIGURED` / `WECHAT_CODE_INVALID` / `WECHAT_UPSTREAM` / `WECHAT_OPENID_BOUND` |
| `app/services/wechat.py` | `code_to_session()`：调 `jscode2session`，错误码映射，**不落库 `session_key`** |
| `app/models/user.py` | `wechat_openid` / `wechat_unionid`（nullable + unique） |
| `app/models/auth_session.py` | `client` 列（`app` / `mp`） |
| `app/services/session.py` | `issue_session(client=...)` + `CLIENT_APP` / `CLIENT_MP` |
| `app/api/v1/routes/wechat.py` | A1 / A2 / A4 / A5 四个端点（带 per-IP 限流） |
| `alembic/versions/c1d2e3f4a5b6_...` | 对应迁移 |

策略 A 下**后端不做 A3（独立注册端点）**：A2 直接复用 `login_or_register`，
与 App「未知手机号自动注册」的语义保持一致。

> **前端仍然拆成了登录页 / 注册页两页**（`pages/bind` + `pages/register`，底部小字
> 互相切换），确认密码只在客户端比对。两页提交的是同一个 A2，靠响应里的 `is_new`
> 区分结果并给出诚实提示 —— 「手机号没人用过 → 已为你创建」「号码已注册 → 已为你登录」。
> 代价是：注册页也能登录、登录页也会注册，这是共用 `login_or_register` 的固有语义，
> 要彻底分开就必须做 A3。当时权衡后选择不动后端（不改鉴权语义、不需要重新部署）。

`resolve_user_id` 里「必须有 `password_hash`」的校验**保持不变** —— 策略 A 保证
微信绑定用户一定走过手机号 + 密码，必然带密码。当初记这个坑的前提（免密注册）
在策略 A 下不成立，改它反而是无谓地动鉴权语义。

**小程序**（`miniprogram/`，主包）

| 文件 | 内容 |
|---|---|
| `utils/config.js` | 后端地址（唯一需改地址处） |
| `utils/request.js` | Bearer 注入 + 拆信封 + 401 会话失效回调 |
| `utils/auth.js` | `wx.login()`、静默登录、绑定 |
| `app.js` | 令牌 + `/me/bootstrap` 首屏数据 |
| `pages/index` | 启动引导：有 token 直接进，没有就静默登录，未绑定则引导 |
| `pages/bind` | 手机号 + 密码，提交前重新 `wx.login()` 取新 code |
| `pages/me` | 头像 / 昵称 / 当前家庭 / 微信绑定状态 / 解绑 / 退出 |

**待办（非代码）**：✅ 已完成。`wo.chunyi-work.online` 已签发 Let's Encrypt 证书，
与现有「裸 IP + 自签证书」并存（按 host 分流），**App 不受影响**；域名也已加进
小程序三类合法域名白名单。

**验收**：App 已有账号 → 小程序打开 → `wx.login()` 后静默登录成功 →
「我的」页显示同一个昵称与家庭名。

### 4.2 P1 壳 + 插件路由（已实现并部署）

后端**零新增** —— 直接复用 `/me/bootstrap` 的 `installed_plugins`。

| 文件 | 内容 |
|---|---|
| `utils/theme.js` | 设计 token，把 `color_token` 映射成卡片底色（分类色 16% 叠白，与 App `alphaBlend` 同算法） |
| `utils/plugin-registry.js` | `plugin_id` → 分包页面；未接入的返回 `null`，卡片标「未开放」 |
| `utils/card-view.js` | `installed_plugins` → 卡片视图模型（纯函数，可脱离小程序环境测） |
| `pages/home` | 4 列网格卡片墙（cw/ch 跨格，clamp 1..4）；矮卡横排；下拉与 `onShow` 静默刷新 |
| `package-memory/pages/timeline` | 回忆分包骨架，P1 只到空态 |
| `app.json` | 加入 home 页、`subpackages`、`preloadRule`、首页/我的 tabBar |

**两个取舍**：

- **插件图标用 emoji 而非 App 的细线图标字体** —— 小程序拿不到那套图标。
- ~~P1 不渲染 `preview.image_urls`~~ —— 当时那些 URL 指向需要 `Authorization`
  头的 `/raw` 端点，`<image>` 发不出自定义头，画了也是空白。P2 的 C1 上线后已补上，
  见下。

**后续补强：首页回忆卡封面（已实现，后端零新增）**

- `utils/card-view.js` 把 `preview.image_urls` 当清单，正则取出末尾的 media id
  （不匹配整串，后端加 query 或改绝对地址都不受影响），矮卡不参与
- `pages/home` 把所有卡的 id 合并成**一次** `POST .../memory/media/urls`，逐卡回填
  直链；图不阻塞首屏，文字先上、图到了再补丁
- 布局改为**图片铺满整卡 + 底部暖棕渐变压白字**。没做 App 那种「左文右图」：小程序
  2×2 卡只有 343×368rpx，左右一分两边都不够看，铺满在任何 cw/ch 下都成立
- 降级链：>1 张才开 autoplay → 1 张静态 → 换不到直链 / `binderror` → 纯文字卡

**验收**：卡片墙渲染出与 App 一致的已装插件与 preview；点「回忆」进入（空）时间线。

### 4.3 P2 回忆 · 读（已实现并上线）

| 文件 | 内容 |
|---|---|
| `app/api/v1/routes/media_url.py`（后端新） | C3 `/me/avatar-url`、C2 `.../members/{uid}/avatar-url` |
| `app/plugins/memory/routes.py`（后端改） | C1 `POST .../memory/media/urls` 批量直链 |
| `app/core/errors.py` | `STORAGE_NO_DIRECT_URL`（501，存储不能预签名时） |
| `utils/media-url.js` | 直链获取 + 按过期时间缓存 + 失败降级；换账号时清空 |
| `package-memory/pages/timeline` | 按月份分组、游标翻页、缩略图、点图直接预览 |
| `package-memory/pages/detail` | 媒体轮播 + 正文 + 留言；作者与留言者真实头像 |
| `package-memory/utils/format.js` | 日期文案，与 App `memory_media.dart` 逐字对齐 |

**两个设计决定**：

- **大图预览用 `wx.previewImage`，不建 gallery 页**。它是小程序原生的全屏图片
  查看器（手势缩放、左右滑、保存），自己写页面做不到这个体验，还多一个要维护
  的页面。
- **日期解析不用 `new Date(iso)`**。`event_date` 是 `2026-05-25` 这种纯日期，
  交给 Date 构造会按 UTC 午夜解析，在东八区变成当天 08:00，跨设备可能出现差一天。
  手动切分年月日再按本地时区构造。

**验收**：能看到 App 里记录的回忆与照片；缩略图正常显示（非空白）；游标翻页正常。

### 4.4 P3 回忆 · 写（已实现）

**后端零新增** —— 这正是 1.2 节那个判断的兑现：回忆插件的 10 条路由本来就能满足
写场景，因为 `wx.uploadFile` **支持自定义请求头**（Bearer 照带），而 `wx.request`
做不到传文件这件事也只在上传时才需要另一条通道。

| 文件 | 内容 |
|---|---|
| `utils/request.js`（改） | `upload()`：`wx.uploadFile` 封装，与 `request()` 同一套错误语义 / 401 处理 |
| `utils/uuid.js`（新） | `client_id` 幂等键（UUID v4），本地生成一次、重试不变 |
| `package-memory/utils/memory-form.js`（新） | 心情 / 可见范围 / 字数上限 / 容量上限，与 App `memory_edit_page.dart` 逐项对齐 |
| `package-memory/pages/edit` | 新建 / 编辑：九宫格媒体、标题正文、日期地点、心情、可见范围、保存进度 |
| `package-memory/pages/detail`（改） | 底部留言输入、删自己的留言、编辑 / 删除回忆、视频走 `previewMedia` |
| `package-memory/pages/timeline`（改） | 悬浮「＋」与空态 CTA → edit 页 |

**三个值得记下来的决定**：

1. **保存顺序固定为「正文 → 删旧媒体 → 传新文件」**。媒体挂点是
   `/memories/{id}/media`，必须先有回忆；删除排在上传之前，避免格子里出现
   「删了又回来」的错觉。
2. **每一步都带 `client_id`**，所以失败后**原地重按保存是安全的**：服务端把它当
   资源 id，重复提交返回第一次创建的那个。因此部分上传失败时**页面不退出**——
   留在原地重试，比替用户做决定好。
3. **上传刻意串行**（`uploadPending`）。并发传大视频失败率明显更高，而且「第
   2/5 个」这种进度提示要串行才有意义。
4. **每条媒体「先直传、失败回退中转」**。直传要三步（换票 → 传 COS → 落库），
   任一步失败都不打断保存，直接降级成 `wx.uploadFile` 到后端 —— 因为直传是优化
   而不是唯一通路。中转路径会重新按字节校验，两条路的落库结果一致。

> ~~P4 的 D2/D3（COS 直传）才需要动后端~~ —— D2/D3 已落地（见 §2 的 D 段）：
> 默认走 COS 直传，100MB 视频不再占后端上行带宽；直传失败时静默回退到
> `POST .../media`（CVM 中转），两条路共用同一套 `client_id` 幂等键。

**验收**：小程序里新建的回忆立刻出现在 App 时间线；App 发的回忆在小程序里能留
言；给回忆加的照片在两端一致；删留言只能删自己的（别人的入口都不显示）。

### 4.5 账号注销（提审合规，已实现并部署 ✅）

合规依据 —— 微信《常见拒绝情形》**3.4.1**：「在用户注销账号后应相应删除相关
数据」；以及《个人信息保护法》第 47 条（撤回同意应删除）与第 4 条（匿名化后
不再属于个人信息）。

**A8 `POST /me/delete-account`**，请求体 `{password}`，处置范围：

| 数据 | 处置 |
|---|---|
| 手机号 / 密码 / 微信 openid·unionid / 恢复码 / 头像 | 清空（手机号与微信标识释放，可被重新注册） |
| 自己创建的回忆、留言，及上传的媒体 | 删除（含 COS 对象） |
| 会话、推送设备、通知、发出的邀请 | 删除 |
| 家庭关系 | 退出全部；主理人自动移交（无人则解散家庭） |

**两个设计决定**：

- **users 行保留、清空到匿名**，而不是硬删 —— 记账/宠物/回忆的 `created_by`
  外键指着它，硬删会让历史记录变孤儿。清空后这行不含个人信息（PIPL 第 4 条
  的匿名化），另打 `deleted_at` 便于审计与二次清理。
- **数据擦除做成插件钩子**（`registry.register(erase_user=...)`）而不是在服务
  层写死 —— 17 个插件里谁持有用户数据谁负责擦除，核心服务不可能知道每张表的
  形状。目前只有 memory 接了钩子，其余插件不持有个人数据。

存储对象**在事务提交之后**才删：先删对象再提交，一旦回滚就删错了，而那是不可逆的。

### 4.6 后续阶段

| Phase | 主题 | 后端 | 小程序 | 验收标准 |
|---|---|---|---|---|
| **P4** | 增强与复制 | A6/A7（App 扫码绑定）、订阅消息 | 分享卡片、新回忆订阅提醒、第二个插件分包 | 一个新插件从"后端已存在"到"小程序可用"仅需 1 个分包的工作量 |

> D2/D3（COS 直传）已从 P4 划掉 —— 已落地，见 §2 的 D 段。A6/A7 仍然挂着 ⏳：
> 它与 §1.0「App 端未接入开放平台 SDK」的决策冲突，要做就得先给 App 接 SDK（那意味着发 APK）。

**依赖顺序**：P3 依赖 P2 的直链解析（编辑页要显示已有媒体的缩略图）。P4 各项相互独立，可任意排序或砍掉。
**最小可用闭环 = P0 + P1 + P2**（能看）✅ 已达成；
**完整链路 = P0..P3**（能看能写）✅ 已达成 —— 这也是"回忆插件打通整个链路"的定义。

> P2 的 C1–C4 是**P0 唯一绕过去的硬约束**。现在「我的」页显示的是 emoji 头像，
> 因为 `/me/avatar` 要带 Authorization 头而 `<image>` 不支持；接上 `/me/avatar/url`
> 后换成真实头像（AGENTS.md 要求：有真实头像就必须显示真实头像）。

---

## 五、决策点（多数已定，剩两条待定）

| # | 决策 | 结论 |
|---|---|---|
| 1 | 微信侧资质 | ✅ AppID/Secret 已提供；**个人主体** → 无 `getPhoneNumber`；域名已备案 |
| 2 | 未绑定 openid 时的首登策略 | ✅ **A** 手机号 + 密码后绑定 |
| 3 | 微信用户是否必须设密码 | ✅ 策略 A 下必然有密码，`resolve_user_id` **不改**（见 §4.1） |
| 4 | 小程序权限范围 | ⏳ 待定 —— 影响 P3 之后是否接 invitations / members 路由 |
| 5 | App ↔ 小程序互跳 | ✅ 不做（App 端未接入开放平台 SDK） |
| 6 | 插件 manifest 是否加 `mp_entry` | ✅ **后端不加**，小程序侧 `utils/plugin-registry.js` 独立维护映射表 —— 接入新插件时后端零改动 |

---

## 六、结论

- **数据互通几乎免费**：同一库 + 同一套 Bearer + 同一套 `require_membership`，
  回忆插件 10 条路由零改动即可给小程序用 —— **读（P2）和写（P3）都是零后端改动**。
- **真正的增量只有两块**：① 微信 openid 与现有账号的绑定（P0，已完成）；
  ② 图片从"带 header 的 302"改成"可直连的预签名 URL"（P2 的 C1–C4）。
  写之所以免费，是因为 `wx.uploadFile` 支持自定义请求头，Bearer 能照带；
  只有 **读**（`<image>`）被硬约束卡住过一次。
- **两个必须提前处理的坑**：① 后端原来是裸 IP + 自签证书，小程序连不上 ——
  需要备案域名 + 公共 CA 证书（App 是 `withTrustedRoots: true`，换证书不影响它）；
  ② 域名白名单必须包含 COS 域名（走 C1 直链方案时）。
- **插件化天然适配小程序分包**：主包只放账号与壳，一个插件一个分包，
  新增插件不动主包，与后端 `registry` 的扩展方式同构。
