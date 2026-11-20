# 本地可移植字节归档

`portable` 仅使用 Go 标准库，在调用端流式打包记录、原图、原视频和缩略图；恢复时先完整校验到权限为 `0700` 的私有临时目录，再发布到全新目标目录。它不是数据库导入器，不会应用归档记录内的旧设备身份、URI、照片 ID、bookmark、权限或家庭关系。

## API 与边界

- `Pack(ctx, writer, manifest, openSource)` / `PackWithLimits`：调用者预先提供严格 manifest，通过 opaque entry ID 打开源字节。打包中源文件丢失、变短、变长、摘要改变或关闭失败都会报错；失败输出必须丢弃，不能提交为成功备份。预先缺件用 `MissingReason` 明确声明。
- `Restore(ctx, reader, RestoreOptions{ExpectedFamilyID, Destination, Limits})`：必须显式提供预期家庭；验证全部 manifest、tar 路径/类型、大小、摘要、精确结束块及 EOF 后才预留目标目录。目标父目录必须已经存在且受调用者控制。调用者应为外部流设置超时，context 无法强制中断任意阻塞的 Reader/Writer。
- `RequirePrivateACL=true` 用于受限明文恢复；当前 Windows 无已验证的原生 ACL 守卫，调用在创建 staging 之前返回 `ErrPrivateACLUnavailable`。`false` 保留调用者明确选择的公开内容恢复路径，但 Windows 目录/文件权限来自父目录继承的 ACL，不能用 Unix mode 宣称用户专属保密；必须由调用者选择可信父目录，原生 ACL 待实机验证。Linux/macOS 私有目录使用 `0700`、文件 `0600`。
- `Result.Files[sourceEntryID]` 给出重新生成的 opaque ID、本机文件路径与摘要。`NewFamilyID`、`NewDeviceID`、`RestoreID` 均重新随机生成。这些是后续受审导入的候选身份，不表示已创建新手机数据库、重建成员权限或完成手机恢复。`RecordsApplied` 固定为 `false`，原始 records 文件保持惰性字节，不反序列化进应用数据库。
- `Complete` 仅表示声明的字节条目齐全，且 photo/video 都有调用方明确确认的 `SourceExact=true`。SHA 相同只证明归档字节一致，不能证明 Android 未脱敏 GPS、picker 未重编码或来源即相册原件。无法证明来源保真时保留字节，但 `UnverifiedOriginals` 标记 `source_not_exact`，`Complete=false`。原图/原视频缺失时保留独立缩略图并返回 `Missing`，不得称为完整备份。
- `MissingReason` 只接受 `not_on_device`、`permission_denied`、`source_missing`、`source_unavailable`、`unsupported`、`not_authorized`、`source_not_exact`。缺件大小必须为 0、摘要为空、`source_exact=false`。

受限内容必须由可信客户端先 `Pack` 再交给 vault 加密；本包不加密、也不提供服务器解密 API。记录正文可包含敏感内容，因此明文 tar、临时文件和恢复目录仅应存在于恢复者控制的可信本机；不能把本包直接接入共享电脑网页明文下载。未完成来源授权或伴侣关系校验前，不应将惰性记录应用为全家可见数据。

## 格式与发布规则

首个 tar 条目固定 `manifest.json`，接下来按 manifest 顺序包含 `entries/<opaqueID>`。仅接受 GNU regular-file header；GNU 二进制大小字段可表示大于 8 GiB 的视频，逐个读取物理 512-byte header 并检查零 padding、两个完整零结束块及随后 EOF，避免标准 tar Reader 隐藏扩展块。禁止符号/硬链接、目录、PAX/GNU 辅助扩展、任意输入目标路径、重复或多余条目。JSON 拒绝重复字段、大小写别名、额外字段、缺字段、null、非法类型和未知枚举。每条记录必须声明 `id/kind/size/sha256/missing_reason/source_exact`，v1 的 kind 为 `records/photo/video/thumbnail`；v2 在此基础上允许显式 `file`（普通附件单个硬上限20MiB，`source_exact=false`）。新 writer 使用 `RequiredVersion(entries)`，无 file 保持 v1；reader 明确拒绝 v1+file 和未知版本。所有文件以 `0600` 创建，不应用源文件权限、文件名或时间。

完整验证后使用 `Mkdir(destination, 0700)` 原子预留目标；并发恢复只有一个能够成功。发布文件用 `O_CREATE|O_EXCL`，最终写 `restore.complete.json`；从不使用可能覆盖现有空目录的 Unix Rename。失败清理仅删除本次创建且 inode 相符的文件，目录只尝试非递归删除。已有目录（包括空目录）及符号链接一律拒绝，不删除、不合并、不覆盖。进程中断或断电可能留下没有 marker 的未完成目录，重试应选择另一个新目标；不得将此目录当作成功恢复。调用方应再次校验落盘媒体及 marker 后执行实际导入。本包不声称抵御同 UID 的恶意进程篡改受信父目录，也不提供跨文件系统断电原子性。

普通 file 不按图片或 records 处理，不执行内容，不应用原文件名；恢复仍为随机私有 `.blob`，仅向恢复者提供校验后的只读字节。当前手机 producer 将所有附件归入 restricted，不新增电脑网页明文许可。

默认上限：20,000 条、manifest 8 MiB、单文件 20 GiB、总字节 100 GiB。可显式下调或在实现上限内配置。流式拷贝使用固定 64 KiB 缓冲；manifest 与条目元数据在内存，媒体不会整文件读入内存。

## 可复现验证

在 `desktop/` 下执行：

```sh
GOTOOLCHAIN=local GOTELEMETRY=off GOPROXY=off GOSUMDB=off \
  /path/to/toolchains/go/bin/go test ./internal/portable -count=1 -v
GOTOOLCHAIN=local GOTELEMETRY=off GOPROXY=off GOSUMDB=off \
  /path/to/toolchains/go/bin/go test -race ./internal/portable -count=1
```

测试使用合成字节，不访问照片、定位、凭据、云服务或真实设备。覆盖私有权限边界、重新映射和二次备份摘要、惰性旧 URI/身份、缺件和未验原件、跨家庭、已有目标、12 并发目标竞争、symlink、重复 JSON/ID、路径穿越/链接、多余 tar 条目、截断/尾随字节、非零 padding、辅助扩展块与缺失结束块抵消、摘要/大小错误、源缺失/变化、限额和取消。大视频测试只验证 10 GiB header 可编码，未实际传输 10 GiB，也不等于 Android/iOS/macOS/Windows 实机验收。
