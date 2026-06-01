# CLAUDE.md

本文件为 Claude Code 在本项目中的工作约定。

## 语言

- 除代码、英文专业术语外，其余文档与交互内容一律使用简体中文输出。
  - 代码本身（标识符、API 字段、命令、日志等）保持原样，不强行翻译。
  - 英文专业术语（如 commit、migration、endpoint、token 等）可按需保留英文。
  - 面向用户的回复、说明、提交信息正文、文档（README/docs 等）使用简体中文。

## CHANGELOG 维护（自动补充）

- 每实现一个新功能，**主动**在 `CHANGELOG.md` 顶部版本条目下补一行简短说明
  （一句话，动宾结构，例如「- 支持上传 / 修改用户头像」）。无需用户提醒。
- 若顶部条目对应的版本**已经发布过**，则在最上方新建一个 `## 下一个版本号`
  条目（并同步递增 `pubspec.yaml` 的 `version`），再把这一行写进去。
- 版本号形如 `0.2.0+2`：`x.y.z` 是展示版本名，`+N` 是 Android versionCode，
  发布脚本据此解析，`+N` 每次发布必须递增。

## 用户 / 成员展示必须接真实头像（设计约束）

只要某个页面要展示「某个用户 / 家庭成员是谁」（作者、记录人、负责人、留言者、
成员列表、指派选择器等），就**必须显示其真实上传的头像，未设置时回退到 emoji**，
不能只用 emoji。新功能设计与实现时默认带上这条，无需用户提醒。

实现方式（已有基础设施，直接复用，不要另造轮子）：

- **后端**：用 `app/services/membership.py` 的 `member_info_map()` 拿成员信息
  （含 `avatar_version` / `has_avatar`），再用 `author_avatar_url(family_id, user_id, info)`
  组装地址；在对应的 Read 模型上加一个 `*_avatar_url: str | None` 字段注入。
  成员头像原图统一走 `GET /families/{fid}/members/{user_id}/avatar?v=N`
  （家庭内成员互相可见），不要为单个插件再造头像端点。
- **前端**：统一用共享组件 `lib/widgets/member_avatar.dart` 的 `MemberAvatar`
  （传 `url` + `emoji`，内部带鉴权头 + 缓存 + emoji 回退），不要在各页面重复写
  `CachedNetworkImage` 或直接 `Text(emoji)`。对应模型加 `xxxAvatarUrl` 字段。

> 头像 URL 带 `?v=版本号`，内容不可变，可长期缓存；换头像时 version 变化自动失效。

## 列表页刷新不能「闪一下」（前端交互约束）

任何展示列表的插件页，**增 / 删 / 改之后刷新时，绝不能把整页换成加载转圈**，否则
列表会「闪一下」（列表 → spinner → 列表），观感很差。新页面默认遵守这条，无需用户提醒。

**反模式（禁止）**：用 `AsyncView` / `FutureBuilder` 直接绑 `_future`，然后在每次操作后
`setState(() => _future = api.xxx())`（常见封装成 `_refreshAll()` → `setState(_reload)`）。
`_future` 一换成未完成的新 future，`FutureBuilder` 立刻进入 waiting 状态把整列换成转圈。

**正确模式**（已在 `lib/features/plugins/memory/memory_list_page.dart`、`stock/*_view.dart`
落地，照抄即可）：

- `_future` **只驱动首屏 spinner**；拉到的数据缓存进一个 `List<T>? _items` 字段。
- `build` 里：`_items != null` 就直接渲染列表；否则才走 `AsyncView`（仅首屏）。
- 增删改后调 `_refreshSilently()`：后台 `await _fetch()` 后 `setState(() => _items = list)`
  **就地替换**，列表全程在屏、不闪。拉取失败就继续显示旧数据，不打断操作。
- 仅「首屏加载失败的重试」(`_retry`) 才清空 `_items` 回到 spinner——那时本就无数据可显示。
- 轮询刷新（如 AI 补充中的定时拉取）同样走 `_refreshSilently()`，否则会周期性闪。

> 单次结果页（详情、二维码、邀请等无列表增删的页面）在「重试 / 重新生成」时显示
> 转圈是合理的，不在此约束内。约束针对的是「列表 + 频繁增删改」的页面。

## APK 发布流程（Claude Code 自己执行）

当用户要求「发布新版本 / 发版 / 上线 App」时，按以下步骤自行完成，无需用户逐步操作：

1. **对齐版本号**：确认 `pubspec.yaml` 的 `version` 与 `CHANGELOG.md` 顶部条目
   版本号一致；若本次要发新版，先递增二者的版本号（`+N` 必须递增），并确保
   `CHANGELOG.md` 顶部条目已收录本次所有更新。
2. **构建 APK**：`flutter build apk --release`（必须用同一签名 key，保证覆盖安装
   不丢登录态）。
3. **发布**：`bash backend/deploy/release.sh`（先 `--dry-run` 预览版本与说明再正式发布）。
   该脚本会从 `CHANGELOG.md` 读版本与更新说明、校验与 pubspec 一致、读取发布密钥
   （`/Users/chunyi/wo_release_token.txt`），再调用 `backend/deploy/publish-apk.sh`。
4. **验证**：`curl -sk https://122.51.81.235/api/v1/app/version` 确认 `version_code`
   等于本次发布的 `+N`。
5. 发布脚本与流程细节见 `backend/deploy/RELEASE.md`。

> 注意：发布会把新版本推送给所有已安装用户，属于线上动作。除非用户已明确授权
> 「发布」，否则构建完成后应先向用户确认再执行 `release.sh`。
