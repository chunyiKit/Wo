# 账号安全修复验证记录

基线：`18c106ac24a4578a3ce2188e4074081397f65362`，远端 main 已两次 fetch 核验，包含已合并 PR #5 与本地连接配置逻辑。修复版本：`2.1.6+56`。

| 检查 | main 基线 | 修复后 |
| --- | --- | --- |
| 后端完整 pytest | 507 passed | 549 passed |
| Flutter 完整 test | 184 passed | 197 passed |
| 后端 Ruff | — | All checks passed |
| Flutter analyze | 36 个既有 info | 相同 36 个 info，无新增诊断 |
| migration | — | 空库 upgrade；两个新增 migration downgrade / upgrade 全通过 |
| APK release build | — | 成功，aapt 确认 versionName=2.1.6、versionCode=56 |
| Git diff 空白检查 | — | 通过 |

- 后端认证新增 23 个用例结果，覆盖无认证接管、无密码与空密码历史 token、dev 默认关闭、摘要存储与私有字段、找回统一错误、过期/一次性/重放、轮换与无效新密码、跨用户隔离、当前/全部撤销、改密撤销、过期会话、限流、认证参数日志脱敏、并发注册、并发重置、重置并发登录、轮换并发重置、等待中的敏感操作与当前/全部撤销竞态。原有认证用例改为安全拒绝旧账号首次设密并使用 Bearer 改密。
- 推送新增 19 个用例结果，覆盖当前/全部退出、改密、找回设备解绑，跨用户和同用户新会话隔离，旧设备安全停用与重新登记，过期/dev 会话拒绝，在途登记与撤销、排队普通/聊天推送与撤销、并发派发去重以及换账号登记与私密发送的竞态。既有设备/推送夹具改用真实测试 Bearer。
- Flutter 新增 13 个测试，覆盖改密/全部撤销清理、撤销网络失败重试、迟到 bootstrap、登录重复/中断与迟到 token、任意请求会话失效、原密码错误与旧响应隔离、生成页离开/重复提交、找回表单校验/超时重试/离开，及改密、当前/全部退出的迟到响应与登录 B、找回 A 后用新密码登录的代际隔离。
- PostgreSQL 18 在独立数据目录、回环端口与三个专用空测试库中运行；测试存储独立。Python 3.13，Flutter 3.44.0 / Dart 3.12.0。没有使用现有开发数据库或生产环境。
- Flutter tester 最初遇到本机代理导致的 WebSocket 握手错误，仅在测试进程删除代理环境变量并指定回环 NO_PROXY 后完整通过；没有修改系统网络或 CA 设置。
- release 构建使用已存在的 ignored 本地 App JSON 配置，经 `bash tool/flutter.sh build apk --release --no-pub` 注入地址；保留仓库现有签名与严格 CA 行为。构建输出有既有 Android/Kotlin 插件迁移、旧 Java 源版本与 Cupertino 字体提示，构建未失败。未上传 APK。
- APK SHA-256：`6f5f11ae11a01f3d43677eb5b9dcda5ebb8de1362d3d4712186040afaff097dd`。
- 原目录 `/Users/chunyi/Wo` 的未跟踪 `.playwright-mcp/` 保留；旧发布目录及产物未改动。

复现时必须提供**独立测试数据库**的 `DATABASE_URL` / `DATABASE_URL_SYNC` 以及测试 `STORAGE_ROOT`，不要对现有或生产库运行本文件中的验证流程。后端依次运行 `alembic upgrade head`、`pytest -q`、`ruff check app tests`；客户端运行 `flutter test --no-pub`、`flutter analyze --no-pub` 和上述独立构建命令。产品迁移与剩余安全边界见 [账号安全与迁移说明](account-security-migration.md)。
