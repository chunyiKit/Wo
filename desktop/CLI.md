# Wo 电脑端命令行

此命令把已授权设备声明的本地字节单向备份到电脑，并提供本机浏览器管理。电脑不会加入手机之间的资料合并，不自动覆盖手机 SQLite。所有命令为显式操作；没有自动打开浏览器、后台云上传或解密服务端点。

## 构建和启动

仅 Go 标准库；在 `desktop/` 下构建，运行数据必须放在 Git 工作区之外：

```sh
GOTOOLCHAIN=local GOTELEMETRY=off GOPROXY=off GOSUMDB=off /path/to/toolchains/go/bin/go build -o /tmp/wo-computer-cli ./cmd/wo-computer
/tmp/wo-computer-cli serve --data /tmp/wo-computer-private-backups
```

`--data` 可省略。默认目录分别为：

| 系统 | 默认数据目录 |
| --- | --- |
| macOS | `~/Library/Application Support/Wo/Backups` |
| Windows | `%LOCALAPPDATA%\Wo\Backups`，要求绝对 LOCALAPPDATA，拒绝其位于 Desktop/Documents/OneDrive |
| Linux | 系统用户配置目录下 `Wo/Backups`，通常 `~/.config/Wo/Backups` |

默认路径避开 Desktop/Documents；显式指定目录仍须自行排除任何网盘同步。数据路径及输入/输出路径拒绝 Git 祖先、文件系统根和路径中的符号链接；包括 `.git` 为 worktree 文件的情况。Unix 已有数据目录须为 0700，不会擅自更改已有目录权限。新目录以 0700 创建。凭据和新归档文件以 0600 创建；Unix 凭据输入若可被其他用户读取则拒绝。

默认 `--listen 127.0.0.1:8787`；`127.0.0.1:0` 可使用临时端口。允许 `localhost`、`[::1]`，以及显式 `--listen 0.0.0.0:8787` / `--listen '[::]:8787'` 接收局域网手机。只绑定单独 LAN IP 会使只允许 loopback 的管理页无法访问，因此明确拒绝，使用显式 wildcard。管理页和管理 API 仍只允许本机 loopback Host。

启动成功只向 stdout 写一行 JSON：

```json
{"event":"listening","url":"https://127.0.0.1:8787","listen":"127.0.0.1:8787","pin":"<证书 SHA256，64hex>","admin_code":"<本次本机管理员代码，64hex>"}
```

IPv6 绑定时管理 URL 为 `https://[::1]:端口`。终端保留该行供本机管理员查看；**不要将实际输出、代码、凭据、密钥或数据目录提交到 Git、分享日志或普通共享目录。** `admin_code` 每次进程启动重建，只在本机页面输入；TLS 是本机自签证书，手机/CLI 必须核对完整证书 SHA256 pin，不能使用忽略 pin 的信任方式。网页浏览器的自签证书交互需平台实测，CLI 不会安装系统 CA。

传输最低 TLS 1.3。HTTP 使用 ReadHeaderTimeout 5 秒、ReadTimeout 2 分钟、WriteTimeout 15 分钟、MaxHeaderBytes 16 KiB。`.state` 保存传输证书/私钥和 `devices.json` 的设备 token 哈希；不保存受限内容恢复密钥。`.state/serve.lock` 通过独占 Mkdir 防止两个服务进程操作同一仓库。SIGINT/SIGTERM 优雅退出，清理本进程仍拥有的锁；崩溃遗留锁会拒绝重启，必须人工检查没有存活服务后处理，命令不会自动删除遗留锁。

## 配对和传输

在本机网页输入本次管理员代码，为目标家庭生成短期一次性配对代码。手机可连入的 `server` 应为电脑在 Wi-Fi 上的 HTTPS origin；管理页 URL 的 `127.0.0.1` 只适用于本机命令。将如下信息放入私有 `pairing.json` 文件，完整字段不可省略：

```json
{"server":"https://192.0.2.10:8787","pin":"<64hex>","code":"<64hex>","family":"family-id","device":"device-id"}
```

示例中的地址仅说明结构，必须换为实际授权服务；不要发送到公网测试地址。pin 取可信启动信息，code 取本机管理页。Unix 此文件须为 0600。认证材料只从文件读取，不接受 token/code/key 命令行参数或 URL 参数。

```sh
/tmp/wo-computer-cli pair --pairing-file /private/path/pairing.json --out /private/path/connection.json
/tmp/wo-computer-cli upload --connection /private/path/connection.json --manifest /private/path/backup.json --files /private/path/files
/tmp/wo-computer-cli fetch --connection /private/path/connection.json --backup snapshot-id --cache /private/path/fetch-cache
```

`--out` 必须不存在，避免消费一次性代码后才发现要覆盖已有凭据。新连接文件是 `{server,pin,token,family,device}`，stdout 只报告 paired/family/device，不输出 token 或 code。连接绑定家庭；upload 的 manifest 和 fetch 取回的 manifest 必须匹配连接家庭。

upload manifest 为 `backup.Manifest`，见 `internal/backup/README.md`；`--files` 是只读目录，文件名固定为条目 `ID.bin`。使用受限 `os.Root` 打开、拒绝 symlink 和非普通文件、校验完整源摘要后分块上传。原件缺失须在 manifest 声明，不能以缩略图或不保真的副本补作原件。fetch 先检查 manifest 家庭，再使用专用非 Git 的字节缓存 `backup.Store`；重复命令继续已确认块，完整性校验不省略。输出为库的实际 status；incomplete 不能当作完整备份。fetch 仅下载归档字节，不能当作已导入手机数据库。

## 公开与受限归档

`pack-public` 使用 `portable.Manifest`，和上传的外层 `backup.Manifest` 是不同契约。详情见 `internal/portable/README.md`。原件条目必须显式声明 `source_exact`；摘要一致仅证明保存的字节相同，不证明平台没有在读取前脱敏或重编码。`--files` 同样只读 `ID.bin`：

```sh
/tmp/wo-computer-cli pack-public --manifest /private/path/inner.json --files /private/path/files --out /private/path/snapshot.wotar
/tmp/wo-computer-cli restore-public --file /private/path/snapshot.wotar --family family-id --out /private/path/new-public-restore
```

公开归档是明文，只用于明确可公开的资料。私密/伴侣受限内容必须在拥有恢复密钥的客户端打包：

```sh
/tmp/wo-computer-cli pack-sealed --manifest /private/path/restricted-inner.json --files /private/path/files --key-file /private/path/recovery.key --backup snapshot-id --entry sealed-id --out /private/path/restricted.woseal
/tmp/wo-computer-cli restore-sealed --file /private/path/restricted.woseal --key-file /private/path/recovery.key --family family-id --backup snapshot-id --entry sealed-id --out /private/path/new-restricted-restore
```

key-file 为 32 个原始字节，或 64 位十六进制文本（可带首尾文本空白），不能直接把密码当密钥。由恢复者保管，与共享电脑归档分开；不可提交 Git。`pack-sealed` 通过 `io.Pipe` 将 `portable.Pack` 直接送入 `vault.Encrypt`，没有明文 tar 暂存；stdout 仅有最终密文 `size/sha256`，可放入外层 manifest 的 sealed 条目，不输出明文摘要/标题/内容。family/backup/entry 构成认证上下文，恢复时必须完全相同。

`restore-sealed` 要求 Unix 私有 0700 父目录；先在其下新建私有临时目录，由 `vault.RestoreFile` 完整认证落地新的 tar，然后 `portable.Restore(RequirePrivateACL:true)` 校验并发布到全新目录，最后只清理本次拥有的临时目录。错误密钥、上下文、损坏和现存目的地均拒绝；不会覆盖现有资料。普通失败清理自建归档输出，输出路径若被替换则拒绝误删并报错；不能承诺文件系统物理擦除或崩溃后自动清理。

Windows 未实现和验证受限恢复 ACL，`restore-sealed` 明确 fail closed；不以 mode 0600/0700 假称 Windows ACL 已验证，不提供绕过开关。服务端只接收密文、没有 decrypt/restore HTTP 端点。

恢复结果为验证后的惰性文件及新 family/device/file ID，`records_applied=false`，不会沿用旧设备身份、URI、Photos ID 或权限。手机端尚需显式安全导入和重建本机媒体引用；此 CLI 本身不能代表完整新手机恢复。缺失原件保留在 missing，无法证明原件字节来源时列 unverified_originals，并标记不完整。

## 本次实际验证

Linux 云机仅使用合成数据与 loopback TLS，无真实照片、位置或服务凭据；没有运行 Flutter/Dart，也没有操作用户设备。

```sh
GOTOOLCHAIN=local GOTELEMETRY=off GOPROXY=off GOSUMDB=off /path/to/toolchains/go/bin/go test -count=1 -v ./cmd/wo-computer
GOTOOLCHAIN=local GOTELEMETRY=off GOPROXY=off GOSUMDB=off /path/to/toolchains/go/bin/go test -race -count=1 ./cmd/wo-computer
```

8 个 CLI 测试覆盖参数拒绝、各平台默认路径避免同步目录、Git/symlink/根路径、public 和 sealed 真实字节往返、错误密钥/家庭/上下文/损坏、只清理本次输出/不覆盖、锁/退出、密钥权限，以及真实 TLS 配对→上传→重复 Fetch。编译不等于 Mac/Windows 原生启动、浏览器信任交互、防火墙入站或手机实机；这些必须分别记录，不能由本机 loopback 测试代替。
