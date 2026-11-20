# 同包 inventory 绑定验证

`packagebinding` 是客户端纯验证模块，不改电脑 HTTP 服务、CLI、业务数据库或手机同步。它不接收恢复密钥，也不生成业务授权证据。

API：

```go
raw, err := packagebinding.Build(actualContext, publicEntries, restrictedEntries)
index, err := packagebinding.Decode(raw) // 只有结构检查，尚未认证
index, err = packagebinding.Validate(raw, outerManifest, innerManifest, actualContext)
err = packagebinding.VerifyPublic(ctx, index, openExactPublicID)
```

固定保留条目 ID 为 `wo_backup_package_binding_v1`。它是 portable v1 内的 `records` 文件，JSON 顶层恰为：`version:1`、`kind:"wo_backup_package_binding"`、`family_id`、`backup_id`、`sealed_id`、`public_entries`、`restricted_entries`。公开仅允许 photo/video/thumbnail，全部业务 records 始终留在加密内层；source_exact 只允许照片/视频声明。公开条目使用完整 `backup.Entry` 元数据（含其可选 label/missing/source_exact）；受限条目使用全部六个 portable entry 字段，不包含索引自身。`Build` 按 ID 排序副本，不改调用者切片；JSON 键及 inventory 顺序不作为权限语义，但索引全文原始字节 SHA 和大小必须匹配内层 manifest。

调用顺序必须是：先以真实 family/backup/sealed 的 `vault.Context` 完成 Vault 认证，再读取经 portable 校验的内层 manifest 和索引字节，再 Validate，最后流式核验公开文件。不能从索引 JSON 推导一个自称可信的 Context，不能把普通 PortableRestore 当来源认证，不能仅凭 UUID 将公开文件连到受限归档。模块不会把返回的 `Index` 当成权限 receipt、旧成员身份、历史操作授权或“整机恢复完成”。

Validate 完整比较 outer 去掉唯一 sealed 后的公开 inventory，以及 inner 去掉唯一固定索引后的私有 inventory，包括 ID、kind、size、全文 SHA、source_exact、缺件理由、公开标签；大小写 ID 冲突在同区、跨区、索引和 sealed ID 之间均拒绝。不同 family、backup、sealed Context 或同 UUID 换包均拒绝。公开可选字段严格遵循 Dart `BackupEntry.toJson` 的省略形状：空 sha256/label/missing、false source_exact 不得显式出现。JSON 重复键（包括转义后同名键）、未知字段、缺字段、null、类型错误、整数溢出、尾随第二 JSON、非 UTF-8、超限均拒绝。

新手机联合导入入口限制：公开最多 4095 条、受限最多 19999 条；**公开+受限合计最多 19999 条**，为索引占用 portable 第 20000 个名额。公开及受限单文件最多 20GiB；**两区全部条目声明字节加索引原始字节合计最多 100GiB**。Build 和 Decode/Validate 都检查实际索引字节；边界测试只构造元数据，不分配 100GiB 文件。通用 `backup.Store` 原有 1TiB 存储限制未改变，此处更小限制是手机联合 portable 导入要求。

`VerifyPublic` 只为声明存在的公开文件核验大小和全文 SHA；缺件不会打开或补造文件。成功不证明平台没有 EXIF 脱敏/转码，也不把 source_exact 的调用方声明升级成来源证明。有缺件、原件保真未确认或历史授权未重建时仍不能称完整恢复。公开文件已经写在电脑不代表手机必须关联；只有绑定和字节校验均成功才能由上层复制到私有 owned workspace。

旧内层没有索引返回 `ErrUnbound`：调用方可在实际 Vault 认证后保留旧 sealed 独立只读，不可按 UUID 自动关联 outer 公开文件。索引本身始终继承内层私有属性。新备份使用新 backup/sealed Context 生成新索引；旧索引可作为私有审计字节保留，不得把它当普通业务 records 或重新沿用旧 Context。

## 实测

仅合成数据、本机 Linux Go，无 SDK、无网络、无真实位置/照片/密钥。10 个顶层测试及其子例覆盖：严格 schema、所有 inventory 元数据差异、跨 Context、大小写/保留 ID、索引全文 SHA、legacy unbound、公开读短/读长/错 SHA/关闭错误/取消、联合条目/20GiB/100GiB 边界。

集成测试实际执行 `portable.Pack` → `vault.Encrypt` → `backup.Store.Create/Append/Finalize/OpenVerified` → `vault.RestoreFile` → `portable.Restore` → Validate → 公开 SHA 核验 → 公开/私有新文件 ID → 新 Context 再备份再恢复。旧业务记录与媒体 SHA 不变，缺件继续保留，旧索引私有审计字节不改。同 UUID 异包公开 inventory 被拒绝；错误实际 AEAD Context 不发布明文。所有照片/视频测试均为明确标注的合成字节，只证明字节协议，不证明图像或视频解码。

复现（仓库 `desktop` 目录）：

```sh
GOTOOLCHAIN=local GOTELEMETRY=off GOPROXY=off GOSUMDB=off /path/to/toolchains/go/bin/go test -race -count=1 ./internal/packagebinding
```

Windows 受限恢复测试按现有库私有 ACL 能力 fail closed，本轮没有 Windows/Mac 原生运行、手机端编译、双端或真机验收；本模块尚待上层接入，不能据此称 UI 或手机恢复完整交付。
