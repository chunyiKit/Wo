# 微信小程序域名接入核查

核查时间：2026-10-15 10:58–11:00 UTC（北京时间 18:58–19:00）。

## 后续已授权路由变更

2026-10-15 12:46 UTC，用户另行批准的 trek API 路由已完成，健康/版本接口严格 TLS 验证均为 200，旧 Android 入口保持 200。仅修改 trek 的 API locations，未部署 PR 后端或迁移。备份、回滚和完整验证见 [变更记录](wechat-trek-routing-20261015.md)。以下为此前核查与计划的历史记录，原 502 观察不代表变更后的 API 状态。

## 结论

三个现有域名目前都不能直接作为已验收的小程序 API 入口。根域与 `www` 已能观察到 Wo 服务，但使用仅匹配服务器 IP 的私有 CA 证书；`trek` 的公开 HTTPS 证书通过本机校验，服务端却返回 502。

用户随后明确确认原 `trek` 服务已下线，并选定 **`https://trek.chunyi-work.online`** 作为小程序 API 入口。该决定替代此前对根域的建议。客户端、Android 构建示例和后端示例已统一目标域名；`connectionReady:false` 保持关闭。这次只更新同一 PR，没有调整线上路由、DNS、证书或服务。

第二次只读复核时间：2026-10-15 11:50 UTC。`trek` 的 A 记录仍是原服务器（TTL 30 秒），AAAA/CNAME 答案为空；正常 HTTPS 信任校验通过，Subject/SAN 均匹配 `trek.chunyi-work.online`，签发者 Let's Encrypt YE2，有效期仍为 2026-08-29 至 2026-11-27。无鉴权 GET `/`、`/api/v1/health`、`/api/v1/app/version` 均为 502。没有绕过 TLS、发送密码或访问家庭接口。用户对原服务下线的确认说明该域名可以复用；502 本身不能证明旧站点配置已删除，也不能确认实际 nginx upstream 或 Wo 监听端口。

下列三域名表格保留第一次核查的观察记录；当前目标仅为 `trek`。

## 用户提供的信息与本次证据

- 用户提供公开 AppID：`wx0619d005f568430c`。
- 用户声明 `chunyi-work.online`、`www.chunyi-work.online`、`trek.chunyi-work.online` 已备案。本次没有查询备案登记系统，DNS 解析、证书与 HTTP 响应也不能独立证明备案状态或小程序主体资格。
- 没有提供或读取 AppSecret；没有读取本机私有部署配置、密钥文件，没有 SSH，也没有登录微信后台。

## DNS

查询系统 DNS 的 A、AAAA、CNAME，三个域名结果一致：

| 域名 | A | AAAA 答案 | CNAME 答案 |
| --- | --- | --- | --- |
| `chunyi-work.online` | `122.51.81.235`，TTL 600 秒 | 空 | 空 |
| `www.chunyi-work.online` | `122.51.81.235`，TTL 600 秒 | 空 | 空 |
| `trek.chunyi-work.online` | `122.51.81.235`，TTL 600 秒 | 空 | 空 |

这是本机解析器在核查时刻的答案，不代表已检查所有地区或所有权威 DNS 节点。

## HTTPS 与公开端点

正常请求均使用域名 SNI、系统信任库，不附加 Authorization、不跟随跳转。

| 域名 | 正常 HTTPS 校验 | `/` | `/api/v1/health` | `/api/v1/app/version` |
| --- | --- | --- | --- | --- |
| 根域 | 失败：curl 60，`unable to get local issuer certificate` | 无法完成可信请求 | 无法完成可信请求 | 无法完成可信请求 |
| `www` | 同根域 | 无法完成可信请求 | 无法完成可信请求 | 无法完成可信请求 |
| `trek` | 通过：curl 0，`ssl_verify_result=0` | HTTP/2 502 | HTTP/2 502 | HTTP/2 502 |

公开证书观察：

| 域名 | 证书 Subject / SAN | Issuer | 有效期（GMT） |
| --- | --- | --- | --- |
| 根域、`www` | `CN=122.51.81.235, O=Wo`；SAN 仅 `IP Address:122.51.81.235` | `CN=Wo Private CA, O=Wo` | 2026-05-25 09:16:56 至 2036-05-22 09:16:56 |
| `trek` | `CN=trek.chunyi-work.online`；SAN `DNS:trek.chunyi-work.online` | Let's Encrypt `YE2` | 2026-08-29 01:31:16 至 2026-11-27 01:31:15 |

根域证书即使手动信任私有 CA，也缺少根域和 `www` 的 DNS SAN；不能通过正常域名校验，不能沿用 App 的私有 CA 信任覆盖解决小程序接入。

为辨认根域现用途，另对根域和 `www` 各做了三次临时 `curl --insecure`、无鉴权、固定公开路径 GET。**此处仅为服务识别证据，不是可信 HTTPS 或微信联调通过证据**，未修改客户端/服务器 TLS 配置：

- 首页均返回 200，内容为 `wo backend up — try /api/v1/health`。
- `/api/v1/health` 均返回 200，数据为 `{"status":"ok"}`。
- `/api/v1/app/version` 均返回 200，公开 Android 发布元数据为 `version_name=2.1.6`、`version_code=56`，发布时间 `2026-10-13T02:07:46.996250+00:00`。

这表明两个域名当前可观察到 Wo 公开服务。发布元数据只表示已发布 Android 版本，不能证明线上后端 Git revision、数据库 migration 或本分支微信功能已经部署。`trek` 首页只有 nginx 502 错误页，无法据此判断其应用用途或上游故障原因。

## 与仓库部署模板的关系

- `backend/deploy/nginx/wo-backend.conf:30` 的 HTTPS 配置是 `default_server`，`:35` 为 `server_name _`，`:37` 引用 `/etc/wo/tls/server.crt`；文件头明确描述 App 使用的私有 CA 模式。`:9` 的 upstream 是 `127.0.0.1:8000`。
- 模板 `:104` 的首页响应与根域、`www` 的公开响应一致。结合证书，这与请求落入现有 Wo 默认虚拟主机的情形一致；这是从公开响应推断，**没有读取线上 nginx 配置证明实际路由关系**。
- 本次已将 `backend/deploy/env/deploy.env.example`、`app.env.example` 和 `config/app.example.json` 的公开目标域名统一为 `https://trek.chunyi-work.online`；真实 `*.local.json`、`deploy.env` 及服务器配置没有读取或修改。示例地址不是已上线证据。
- 实际仓库公开存活路径为 `/api/v1/health`，处理器不访问数据库。本次没有请求 `/api/v1/health/db`、家庭接口、登录接口、APK 下载或发布接口。

## 最小变更计划（尚未执行，需另行授权）

| 项目 | 拟实施的最小改动 | 当前边界与验收 |
| --- | --- | --- |
| DNS | 保持现有 `trek` A 记录，不新增子域、不改根域或 `www` | 当前解析已指向现有服务器，无证据需要修改 DNS |
| nginx 路由 | 先只读检查现有 `trek` 精确 vhost 和 Wo 实际监听端口，再仅调整已下线 `trek` 站点的 API upstream | 仓库示例为 `127.0.0.1:8000`，线上实际配置尚未读取；不能盲目追加同名 vhost |
| TLS | 沿用 `trek` 当前公开可信证书及续期配置，确认完整链与实际文件路径 | 不重新签私有 CA，不替换旧 IP 证书，不改 `trek` 的 ACME/80 端口续期规则 |
| 后端 | 仅在本 PR 审核合并并另获部署授权后，备份、执行 migration 并发布相应后端代码 | 先路由到现有 Wo 只会得到旧接口，不能证明新增微信接口已上线；禁止部署未合并分支 |
| 服务端环境 | 确认何时将 `WEB_BASE_URL` 改为 `https://trek.chunyi-work.online`，安全注入已知 AppID 和用户自行配置的 AppSecret | `WEB_BASE_URL` 会改变新生成邀请链接等公开 URL，需要一起验收；不读取或索取聊天中的秘密 |
| 微信后台 | 后续获准后设置 request / uploadFile / downloadFile 为 `https://trek.chunyi-work.online`，完成类目及隐私指引 | 域名选择不等于后台修改授权；目前未登录后台 |
| 小程序 | 完成隔离账号联调、可信健康检查和真机权限/上传验证后，才单独开启 `connectionReady` | 当前仍为 false；不能用绕过 TLS 或域名检查作为替代 |

可审查的 [nginx 示例](../backend/deploy/nginx/wo-miniprogram.conf.example) 只声明 `trek`，没有 `default_server`，不修改现有 `wo-backend.conf`；证书路径和上游地址是待现场确认的示例，不能直接覆盖线上文件。本机没有 nginx，尚未运行真实 nginx 配置解析；本地回归只检查配置范围及目标一致性。未来实施必须先备份原 `trek` 站点配置、检查重复 `server_name`、执行 `nginx -t`，通过后才能 reload；失败回滚仅恢复这次改动的 `trek` 配置。

## Android 兼容影响

- 已安装 Android 包的 API 地址在构建期注入，修改 `config/app.example.json` 或小程序配置不会改变现有包。现有 IP/default_server、原证书和 API 路径均应保留；不要全局重定向旧 IP 到 `trek`，也不要让 `trek` 的证书成为默认 IP 证书，否则旧包可能因主机名校验失败而断连。
- 后端身份表 migration 是新增表；复用同一 Wo 数据库及会话存储，不重建家庭、不导出真实记录、不撤销现有账号或会话。后端仍须通过原 App 的回归和迁移预检后才可部署。
- `lib/data/wo_http_overrides.dart` 使用 `SecurityContext(withTrustedRoots:true)` 并附加原 CA，因此从代码上看，未来授权构建的新 Android 包可使用公开可信的 `trek` 证书。此为源码兼容判断，尚非真机握手成功；不需要为小程序复制 CA 或放宽证书校验。本次没有修改 Flutter HTTP 安全逻辑。
- 示例保留原 `/api/v1` 路径、视频和 APK 的大小/超时语义，供未来新移动端版本使用；不能通过替换旧部署配置来隐式切换所有 Android 用户。
- 上线顺序不变：后端迁移支持 → 发布移动端同步旧手机本地记录 → 最后开放小程序。旧 SQLite 家聊、图片和未完成私人草稿仍需另行迁移，不自动重发，不自动共享。

## 需要用户后续确认或提供

1. **域名选择已确认，无需再次确认。** 仍需明确授权：在保留旧 Android 默认入口的前提下，检查并修改已下线 `trek` 的精确 nginx vhost、做 `nginx -t` 和 reload。实际证书路径、Wo upstream、配置备份和回滚方式在实施前核对。
2. 单独确认本 PR 合并、后端 migration/部署及 `WEB_BASE_URL` 切换的时机；本次未获得这些上线动作授权。
3. 由用户在服务端安全配置 AppSecret，并告知已完成即可，不在聊天中发送。公开 AppID 已配置为 `wx0619d005f568430c`。
4. 提供微信开发者/体验成员资格、个人主体已获准服务类目和隐私指引完成状态；后台合法域名修改及真机联调另行获准后进行。

本次未修改 DNS、nginx、证书、微信后台或生产环境，未发版、未上传记录，也未向家庭成员发送消息。可信 TLS 复核通过仅证明当前证书有效；Wo 路由、真实 code 交换、微信合法域名及真机行为仍未联调通过。
