# 发布新版本 App（应用内更新）

面向运维：如何把一个新的 Android APK 推送给已安装用户。

后端只保存「一个最新 release」（APK + manifest），发布即覆盖上一个。App 在
「我的 → 关于「窝」→ 检查更新」里读取最新版本，按需下载并调起系统安装器。

---

## 一次性准备（每台服务器只做一次）

1. 在服务器生成发布密钥并写入 `/etc/wo/app.env`：

   ```bash
   openssl rand -hex 24          # 复制输出
   sudo nano /etc/wo/app.env     # 加一行 APP_RELEASE_TOKEN=<上一步的串>
   sudo systemctl restart wo-backend
   ```

   - 密钥为空时，发布接口 `POST /app/release` 返回 403（即发布被关闭）。
   - 这个密钥**不进代码库**，只在服务器和发布者手里。

2. 确认 nginx 已是仓库里的版本（`deploy.sh` 会自动安装）。`/api/v1/app/`
   放行了 200MB 上传与更长超时，APK 才能正常上传/下载。

---

## 每次发布（推荐：一键脚本）

平时按这个流程，不用手敲版本号和参数：

1. 在 `pubspec.yaml` 递增 `version`（如 `0.2.0+2`，`+N` 必须递增）。
2. 在 [`CHANGELOG.md`](../../CHANGELOG.md) 顶部加一个同版本号的条目，列出本次更新（每条一句话）。
   每完成一个需求就往最新条目里加一行。
3. 用同一签名 key 构建：`flutter build apk --release`。
4. 发布：

   ```bash
   bash backend/deploy/release.sh            # 正式发布
   bash backend/deploy/release.sh --dry-run  # 先预览将发布的版本与说明
   ```

   `release.sh` 会从 `CHANGELOG.md` 顶部读版本与更新说明、校验与 `pubspec.yaml`
   一致、读取发布密钥（`/Users/chunyi/wo_release_token.txt`），再调用下面的
   `publish-apk.sh` 完成发布并回传状态。

下面是它底层用到的 `publish-apk.sh` 手动用法（需要单独指定版本/路径时用）。

## 每次发布（手动）

### 1. 递增版本号并构建

在 `pubspec.yaml` 把版本号往上调，**build number（`+N`）必须比上一版大**——
App 就是靠它判断「有没有新版」：

```yaml
version: 0.2.0+2     # 0.2.0 是展示版本名；+2 是 versionCode（必须递增）
```

然后用**同一个签名 key**构建 release APK（同包名 + 同签名才能覆盖安装、
保留登录态，不需要用户重新登录）：

```bash
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

### 2. 发布到服务器

```bash
WO_RELEASE_TOKEN=<服务器上的 APP_RELEASE_TOKEN> \
bash backend/deploy/publish-apk.sh \
    --apk build/app/outputs/flutter-apk/app-release.apk \
    --name 0.2.0 \
    --code 2 \
    --notes "新增应用内更新；修复若干问题"
```

成功时会打印新 release 的 JSON（含 size / sha256）。

### 3. 验证

```bash
curl -k https://122.51.81.235/api/v1/app/version
```

`data.version_code` 应等于本次的 `--code`。然后在一台旧版本手机上进
「关于「窝」→ 检查更新」应能看到新版本。

---

## 参数说明

### publish-apk.sh 参数

| 参数 | 必填 | 说明 |
|------|------|------|
| `--apk`   | 是 | APK 文件路径 |
| `--name`  | 是 | 展示版本名，对应 pubspec 的 `x.y.z`，例如 `0.2.0`。仅用于展示 |
| `--code`  | 是 | versionCode，**必须等于** pubspec `+N` 里的 `N`，且大于线上当前值。App 据此比较 |
| `--notes` | 否 | 更新说明，展示在「关于」页。建议简短一句话 |

### 环境变量

| 变量 | 必填 | 默认 | 说明 |
|------|------|------|------|
| `WO_RELEASE_TOKEN` | 是 | — | 必须与服务器 `APP_RELEASE_TOKEN` 一致 |
| `WO_API_BASE_URL`  | 否 | `https://122.51.81.235` | 后端地址 |
| `WO_CA_CERT`       | 否 | — | 自签 CA 证书路径；不设则用 `curl -k` 跳过校验（仅发布通道，App 本身仍校验 CA） |

---

## 接口速查

| 方法 | 路径 | 鉴权 | 用途 |
|------|------|------|------|
| GET  | `/api/v1/app/version`  | 无 | 取最新版本元信息；未发布时 `data` 为 `null` |
| GET  | `/api/v1/app/download` | 无 | 下载最新 APK |
| POST | `/api/v1/app/release`  | `X-Release-Token` | 发布/覆盖最新 release |

---

## 常见问题

- **发布返回 403**：服务器没设 `APP_RELEASE_TOKEN`，或设了空值。
- **发布返回 401**：`WO_RELEASE_TOKEN` 与服务器不一致。
- **App 检查更新说「已是最新」但确实发了新包**：`--code` 没比线上大，或没比
  用户手机上的 build number 大。确认 pubspec 的 `+N` 已递增、`--code` 与之一致。
- **上传报 413**：APK 超过 200MB。调大后端 `APP_RELEASE_MAX_BYTES` 和 nginx
  `client_max_body_size` 后重启。
- **用户更新后要重新登录**：基本是因为换了签名 key 或包名导致被当成「全新安装」。
  务必用同一签名发布。
