# 微信身份接入（首版）

本次仅提供后端代码与 migration，未连接真实微信、未运行生产 migration、未部署。Flutter 客户端继续使用原接口；小程序复用 `/api/v1`、opaque Bearer session 与家庭权限校验。未接支付、金融插件、手机号授权接口或微信系统推送。

## 配置与接入

由管理员通过现有服务端环境配置机制注入下面三项，**不要把 AppSecret 写入仓库、小程序、日志、截图或聊天**：

```dotenv
WECHAT_APP_ID=wx0619d005f568430c
WECHAT_APP_SECRET=<仅服务端保存的 AppSecret>
WECHAT_TIMEOUT_SECONDS=10
AUTH_DEV_SHIM_ENABLED=false
```

AppSecret 在 Settings 中使用 `SecretStr` 避免常规 repr 泄漏。缺 AppID 或 AppSecret 返回 503，绝不会自动启用假微信身份。上游固定 `https://api.weixin.qq.com/sns/jscode2session`；不接受客户端提交 openid / unionid / session_key，不存储或返回 session_key。httpx 的该端点请求日志已脱敏；生产网关、代理与追踪系统也应禁止采集该上游 URL 查询参数与鉴权请求体。测试使用 `httpx.MockTransport` 或测试级 monkeypatch，运行时没有测试身份开关。

公开 AppID `wx0619d005f568430c` 已收到并写入小程序项目；用户确认 `chunyi-work.online`、`www.chunyi-work.online`、`trek.chunyi-work.online` 已备案，用户已确定使用原服务下线的 `https://trek.chunyi-work.online`。只读复核其 TLS 校验通过、公开路由仍为 502；部署改动尚未授权。剩余最小信息是：对 `trek` 最小路由改动的明确授权、由用户自行完成的 AppSecret 服务端安全配置、开发者工具体验成员及个人主体实际可用类目/隐私声明核验结果。无需在聊天中发送任何秘密。当前实现不依赖手机号授权能力；原账号手机号是用户手工输入的登录标识，不宣称验证了手机号所有权。

正式域名须为有有效公信证书的 HTTPS，目标已选定 `https://trek.chunyi-work.online`，在微信后台配置对应 request / uploadFile / downloadFile 合法域名。禁止裸 IP、自签 CA 覆盖或以跳过域名校验作为正式方案。家庭头像、回忆附件继续经既有家庭权限校验和 Authorization 请求头下载，禁止公开私有 COS、禁止把 Bearer 放 URL。

## API

请求均为 JSON。下列路径在 `/api/v1` 下，成功与错误沿用既有响应 envelope。鉴权结果与错误均 `Cache-Control: no-store`。code 是每次 `wx.login` 的单次凭据；未知身份登录检查后，注册或绑定必须重新获取 code。

| POST 路径 | 请求 | 成功 data |
| --- | --- | --- |
| `/auth/wechat/login` | `{code}` | 已绑定：`{user,token,is_new:false}`；未知：`{registration_required:true}`，不自动注册 |
| `/auth/wechat/register` | `{code,password,display_name?}` | `{user,token,is_new:true,recovery_code,recovery_expires_at}` |
| `/auth/wechat/bind` | `{code,phone,password}` | 仅原账号手机号 + 正确密码：`{user,token,is_new:false}` |
| `/auth/wechat/reset-password` | `{code,recovery_code,new_password}` | `{changed:true,logged_out:true}` |

新微信用户 `phone=null`，要求自设符合原密码策略的密码，保存哈希以兼容现有 session 安全约束。注册生成一年有效的一次性恢复码，只返回一次；客户端应明确让用户安全保存，勿写进共享家庭内容。登录后可通过既有 `/auth/recovery-code`（当前密码复核）更新恢复码。已有账号绑定保留原 user_id、家庭、恢复码与权限；不会因相同手机号、昵称、unionid 或其他相似信息合并账号。未知手机号绑定失败，不会顺便创建账号。原无密码老账号仍需线下可信恢复流程。

微信恢复需要当前有效 code 加预先保存的恢复码；单凭微信身份不能重置密码。恢复后销毁旧恢复码并撤销全部现有 session / 设备 token，与原密码恢复相同。微信身份映射本身仍为有效登录因素；当前未提供解绑、换绑或人工恢复管理接口。

身份表同时约束 `(app_id,openid)` 和 `(app_id,user_id)` 唯一。同一 AppID 下一个微信身份只映射一个原账号，一个原账号只绑定一个微信身份。并发首次注册/绑定发生冲突时整笔事务回滚，不残留孤儿用户。已有账号登录发 session、绑定与恢复共用用户行锁，恢复与全局 session 撤销不会和 session 发放交错。

IP / 微信身份限流覆盖所有微信鉴权入口，绑定还共享原手机号登录限流。与现有登录一致，这些是单进程内存限流；多 worker / 多副本上线前需要共享限流（例如网关或 Redis），不能把本地进程 limiter 当成全局防护。

## Migration 与本地测试

新增 revision `d091bc34ea12`，接在 `9d94a701bf23` 后，只创建 `wechat_identities` 与唯一索引；不回填、不修改或上传旧记录。上线操作由用户另行授权后执行。下面命令必须指向**隔离测试库**：

```sh
cd backend
# 使用已有 Python 虚拟环境；先在当前终端配置隔离 DATABASE_URL / DATABASE_URL_SYNC。
python -m alembic upgrade head
python -m pytest tests/test_wechat_auth.py tests/test_auth.py
```

无需数据库的上游交换与输入脱敏测试：

```sh
python -m pytest tests/test_wechat_auth.py -k 'exchange or missing_credentials or validation'
```

测试账号、密码、code 和微信身份全部是合成值。真实 code 交换、真实 AppID、微信开发者工具与真机 HTTPS 下载等需要正式接入信息后另外验证，MockTransport 测试不能证明真实微信联调完成。

## 切换前置条件

用户确定的顺序仍为：先完成后端迁移支持，再发布移动端同步旧手机本地记录，最后上线小程序。本次没有发布移动端、自动上传真实本地记录或执行 Android 迁移。家聊默认服务端只保留 7 天，旧 SQLite 历史、图片与未完成私人草稿仍须单独设计迁移；禁止自动重发待发送消息，禁止把私人草稿变为共享家庭内容。
