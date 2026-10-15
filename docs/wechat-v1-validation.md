# 微信小程序首版验收记录

2026-10-15，基线为重新核实的 GitHub `main@24b1cbf1d46e5f05f3b26664fdf2b394f7bb20a0`、已发布 Android `2.1.6+56`。独立克隆位于 `Wo-miniprogram`，分支 `feat/wechat-miniprogram-v1`；原 `/Users/chunyi/Wo` 的 main 和未跟踪 `.playwright-mcp/` 未改动。`2.1.7+57` 仅按 AGENTS 维护为下一版，未发版。

## 自动验证

| 检查 | 结果与边界 |
| --- | --- |
| 新空库全量 Alembic upgrade head | 通过，到 `d091bc34ea12`；一次性本机 PostgreSQL 18，独立端口和 `/tmp` 数据目录，未连接既有库 |
| 16 个相关后端测试模块 | 235 项通过，覆盖微信交换替身、绑定并发/禁止合并、恢复/撤销、家庭权限与原记账/家务/回忆行为 |
| 私有媒体测试（包含于上行） | 42 项通过；额外使用内存 SQLite、假 COS，覆盖四个鉴权下载端点、跨家、private 作者和默认 App 兼容 |
| 原生客户端 Node 测试 | 59 项通过；wx 是受控替身，覆盖模板、登录/恢复码离页、session 隔离、新用户家庭闭环、金额/时区、无闪烁、稳定 ID 与断点恢复、媒体并发 |
| TypeScript | 6.0.3 `--noEmit` 通过；另以微信官方 API typings 对 Wx 参数独立检查零诊断，按结果换用 FileSystemManager 文件 API |
| Ruff | 所有新增/修改 Python 模块及测试通过 |
| git diff --check | 通过 |
| 主包保守静态统计 | 约 159 KB（TypeScript 源、WXML、WXSS、图片等）；不是开发者工具实际编译包体，工具检查阈值 1.5 MB，单文件 300 KB |

后端回归命令（环境须显式指向隔离测试库）：

```sh
python -m pytest tests/test_wechat_auth.py tests/test_miniprogram_media.py \
  tests/test_account_security.py tests/test_auth.py tests/test_push_session_security.py \
  tests/test_memory.py tests/test_accounting.py tests/test_accounting_categories.py \
  tests/test_accounting_trend.py tests/test_chore.py tests/test_bootstrap.py \
  tests/test_families.py tests/test_invitations.py tests/test_me_avatar.py \
  tests/test_members.py tests/test_family_background.py -q
```

客户端：`node --test miniprogram/tests/*.test.cjs`、`tsc --noEmit -p miniprogram/tsconfig.json`、`node miniprogram/tools/check-package.cjs`。本机复用已有 TypeScript、Python、Pillow、PostgreSQL 与 Playwright；未安装新软件。官方声明来源为 [微信 API typings](https://raw.githubusercontent.com/wechat-miniprogram/api-typings/master/types/wx/lib.wx.api.d.ts)，只下载到临时目录供核对，不执行其内容。

## 独立审查与修复

两轮独立审查覆盖身份/权限、实际 API 契约、客户端状态与模板。已修复：WXML 条件缺少绑定、回忆路径双斜杠、新微信账号不能进入家庭、UTC 直接切片错日、恢复码离页后迟到回显、原生不支持的 br 标签、照片压缩比例、旧账号状态回填，以及首屏批量原图下载。回忆分享最后回执丢失后重试会先确认恢复私密，防止追加附件在已分享记录上提前可见。

媒体池额外模拟验证：最多 4 并发；换账号后排队任务不再发网，迟到文件被删除。缓存索引上限 80 个，临时文件在账号/家庭切换时清理；单次长会话点击大量图库仍会积累临时图片，后续可增加按字节清理预算。

## 浏览器视觉检查

下图由 `miniprogram/tools/visual-preview.cjs` 读取**实际 WXML/WXSS**、以合成家庭/金额/记录映射到 HTML 后，在本机 Chrome 390×844 截图。所有名字、账目和头像均为合成演示，没有使用真实家庭数据。

这些图片仅证明浏览器布局检查，不能证明微信模板编译、原生样式、字体、权限、相册或网络成功。浏览器默认表单控件与原生组件仍有差异。视觉以当前 Flutter `home_page.dart`、`family_home_background.dart`、`wo_cinema.dart` 与 `wo_tokens.dart` 为基准；没有替换原 App。

| 页面 | 截图 |
| --- | --- |
| 日落影院首页 | [查看](../output/playwright/home-cinema.png) |
| 暖纸首页 | [查看](../output/playwright/home-paper.png) |
| 登录 | [查看](../output/playwright/login-cinema.png) |
| 记账 | [查看](../output/playwright/accounting-cinema.png) |
| 家务 | [查看](../output/playwright/chores-cinema.png) |
| 回忆图片 | [查看](../output/playwright/memories-cinema.png) |

日落 PNG 从 2,055,164 字节优化为 54,143 字节 JPEG。25,125,512 字节原字体不进小程序主包，使用系统衬线回退；可选远程字体的成功/失败调用路径已测，真实字体下载与中文覆盖尚未测。

## 尚未验证与接入条件

已收到公开 AppID `wx0619d005f568430c` 并写入 `project.config.json`。本机没有发现微信开发者工具（`Developer.app` 为 Apple Developer），未安装或接受新软件条款；所以尚无开发者工具编译、实际包体、原生截图或 Android/iOS 真机验收。

[域名核查](wechat-domain-readiness.md) 表明根域/`www` 当前承载 Wo 但证书不合格，`trek` 证书有效但返回 502。用户已进一步确认原 `trek` 服务下线并选定该域名作为 API 入口；第二次只读复核其可信 TLS 通过、三条公开路由均 502。客户端与后端示例现统一为 `https://trek.chunyi-work.online`，但 `connectionReady:false` 阻止联网。最小路由改动及 Android 兼容计划见域名核查文档，线上变更仍需明确授权。

还需：可信 HTTPS 与后端部署准备、用户在服务端安全注入 AppSecret、小程序开发者资格、后台 request/upload/download 合法域名、个人主体服务类目与隐私指引。未请求、读取或输出任何密钥文件；未将 AppSecret 放到客户端、日志或聊天。

没有真实微信 code 交换、真实 COS 下载联调、真实记录上传、生产 migration、线上配置变更、Android 发布、合并或成员消息。家务指派和邀请码确认加入的将来实际使用会沿用现有站内通知规则；本次只运行合成测试。上线顺序仍为后端迁移支持→发布移动端同步旧手机本地记录→上线小程序；旧家聊 SQLite、图片和私人草稿另行迁移，禁止自动重发或共享私人草稿。

## 目标域名后续修订

用户选定 `trek.chunyi-work.online` 后，仅修正本地模板、文档及同一 PR，未部署。本次新增 3 项域名配置回归，与原 8 项连接脚本回归共 11 项通过；59 项客户端测试与 TypeScript 检查也重新通过。配置回归均使用本地替身；本次不重跑未改动的后端业务测试，也不把旧的 235 项结果冒充新的线上联调证据。
