# 微信小程序域名接入核查

核查时间：2026-10-15 10:58–11:00 UTC（北京时间 18:58–19:00）。

## 结论

三个现有域名目前都不能直接作为已验收的小程序 API 入口。根域与 `www` 已能观察到 Wo 服务，但使用仅匹配服务器 IP 的私有 CA 证书；`trek` 的公开 HTTPS 证书通过本机校验，服务端却返回 502。

建议优先把 `https://chunyi-work.online` 作为**待配置的 Wo API 入口**：后续经单独授权，为根域新增精确匹配的 HTTPS 虚拟主机及匹配该域名的公开可信证书，代理现有 Wo 后端；保留现有 IP 默认虚拟主机和 `trek` 虚拟主机，避免影响旧 App 或其他服务。本次未应用任何线上配置；客户端已将该域名写入待接入模板，但 `connectionReady:false` 主动阻止请求，尚不能作为可用入口。

若根域另有网站规划，可改用独立的 `wo-api.chunyi-work.online`；这是建议名称，**未核查该子域现有解析、占用或证书**，不能当作已经可用的入口。无需为了小程序覆盖 `trek` 服务。

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
- `backend/deploy/env/deploy.env.example` 的域名仍是 `https://api.example.com` 占位，不能据此认定域名已接入。
- 实际仓库公开存活路径为 `/api/v1/health`，处理器不访问数据库。本次没有请求 `/api/v1/health/db`、家庭接口、登录接口、APK 下载或发布接口。

## 后续最小接入事项

1. 选定根域或独立 API 子域；新增精确 `server_name` 和包含该域名 SAN 的公开可信完整证书链，保留旧 IP 默认虚拟主机及其他站点。具体线上修改与发布另行授权。
2. 用**不带** `--insecure`、私有 CA 覆盖或裸 IP 的请求验证 `/api/v1/health`；确认 API 可用及微信登录 migration、服务端新代码按既定上线顺序部署。
3. 在小程序后台配置选定 HTTPS 主机对应的请求、上传和下载域名，并在开发者工具及真机验证；当前没有后台或真机证据。
4. 通过用户受控的服务端配置渠道提供 `WECHAT_APP_ID` 与 `WECHAT_APP_SECRET`，不写入仓库、客户端或聊天。公开 AppID 已收到，AppSecret 尚缺。
5. 确认 `miniprogram/core/config.ts` 的 `apiOrigin` 为最终经验证入口后，再将 `connectionReady` 改为 `true`。媒体继续走同一鉴权域名的 `download=true`，Bearer 只放请求头，家庭 COS 保持私有。

本次未修改 DNS、nginx、证书、微信后台或生产环境，未发版、未上传记录，也未向家庭成员发送消息。HTTPS、微信真实 code 交换、小程序后台合法域名及个人主体接口资格尚未全部验证，不能宣称真实联调成功。
