# 恢复者持钥的加密归档容器

此包只负责不透明字节流加密和完整性检查，不实现配对、账号、访问控制、密钥分发或内层归档。32 字节随机恢复密钥必须由恢复者保存，电脑保存端不可获取密钥。密码不得直接当密钥，本包不提供口令派生。不得将密钥、受限条目名称、Context、明文摘要写进电脑公开元数据、网页或日志。

## 接入接口

- `Encrypt(dst, src, key, Context{Family, Backup, Entry}, Limits{}) (Summary, error)`：固定内存流式加密。错误时可能已写不完整密文前缀，调用者须先暂存并在成功后提交。
- `InspectHeader(src) (Header, error)`：只读取 52 字节公开头，检查 magic/version 和固定块大小，返回最小密文长度 121，调用者另核对实际大小。**无钥检查不认证密文、上下文、完整性或来源**，不得据此标记备份可恢复。
- `Verify(src, key, context, limits) (Summary, error)`：完整认证并丢弃明文，要求终帧及真实 EOF，不输出部分内容。
- `RestoreFile(root, name, src, key, context, limits) (Summary, error)`：Windows 当前在读取输入或创建暂存之前返回 `ErrPrivateACLUnavailable`，暂不支持明文恢复。Mac/Linux 在 `os.OpenRoot` 打开的调用者可信私有目录创建新文件。先把密文写入 0600 随机暂存并完整验证，再解密到私有明文暂存，复验、fsync、原子不覆盖 hard link 发布。任何已有目的地（包括符号链接）均拒绝，并发创建也不能被覆盖。文件系统不支持 hard link 就返回错误。

成功摘要为明文字节数、数据块数、SHA-256，只有恢复者侧可用，不可作为电脑公开索引。Context 三字段必填、每个最多 4096 字节 UTF-8、不含 NUL，须由可信授权清单传入；错误 family/backup/entry 不能恢复。Context 不写入公开头。外层使用不含标题的随机 entry ID；受限条目数量与正文须由调用方放在内层加密，不能一条记录一个公开标题。

默认上限 64 GiB 明文、1,048,576 数据块；零值为默认，可显式调低。硬上限 1 TiB、16,777,216 数据块，nonce 序号不会溢出或重用。密文额外空间为每块 25 字节及固定头/终帧。内存为固定 64 KiB 级；恢复需要整份密文和整份明文暂存的磁盘空间、两次读取/认证。调用者另按磁盘余量限制并发/总量，并对网络 Reader 设置超时或取消。单容器限额不能代替服务器总配额。无进度读取最多 100 次后失败，但本包不能中断一个阻塞的 Reader。

## v1 字节契约

整数均大端。公开头：`WOVLT1\r\n`（8）+ 随机 salt（32）+ 随机 nonce 前缀（8）+ 固定 chunk size `65536`（4），共 52 字节。每次从 `crypto/rand` 取新 salt/nonce。标准 HKDF-SHA256 extract/expand 由恢复密钥、salt、长度前缀 Context 的 SHA-256 派生 AES-256-GCM 密钥；info 为 `WoVault/AES256GCM/v1\0 || contextHash`。

每帧：`kind:u8 || sequence:u32 || plaintextLength:u32 || GCM(ciphertext+tag)`。GCM nonce 为头中随机前缀（8）与 sequence（4）。AAD 为 `WoVault/frame/v1\0 || header || contextHash || frameDescriptor`。Context hash 输入为 `WoVault/context/v1\0` 与依序三个 `byteLength:u32 || UTF8` 字段。

数据帧 kind=1，sequence 从 0 严格递增，长度 1..65536；不足整块的数据帧只能是最后一个数据帧。终帧 kind=2，使用下一个未用的 sequence，明文固定 44 字节：`totalBytes:u64 || chunks:u32 || plaintextSHA256:32`。空文件仍有终帧。校验所有帧、计数、摘要、终帧及 EOF，拒绝重排、重放、跨归档拼接、截断和尾部垃圾。头、帧描述符和 Context 均受认证；公开头本身没有独立认证，不能推断内层条目列表。

## 安全与恢复边界

网络授权由调用方实施：共享电脑管理员不可下载受限条目，恢复手机可凭配对凭据取密文，恢复密钥仍只在手机/恢复者手里。目录和输出名的选择不等于完成授权。

Mac/Linux 根目录须已由调用者建成并确认属于可信用户的私有目录，本包不自动推定其私有。Windows 的 mode 0600/0700 不等于私有 ACL：在原生 ACL 创建、所有者/访问主体校验及对应系统测试完成之前，`RestoreFile` 一律 fail closed；仅 `Encrypt`、`Verify`、`InspectHeader` 保持可用，不能用临时路径或调用者声称已设权限绕过此限制。目录不能同时被不可信同用户进程修改。`os.Root` 防止路径越界；本包只接受安全叶名，拒绝 Windows 保留名/字符，不能防御已控制同一用户/进程的攻击者。

普通失败删除本次暂存且不发布明文；错误密钥或损坏输入首遍失败时不创建明文暂存。文件系统拒绝清理返回 `ErrCleanup`，须隔离目录并明确报告。强杀、断电或操作系统崩溃仍可能留下私有暂存；接收目录不可被公开下载或系统备份，启动时应安全清理本应用已确认的残留。删除不保证物理擦除，运行时 AES 密钥副本也不承诺法证级内存擦除。

本包不解决撤销已复制的密文/密钥或明文。完整恢复还须验证内层清单、业务权限、原图/原视频独立摘要，重建新设备媒体引用与身份，拒绝静默覆盖现有数据库；这些不在本包中。

## 当前验证

仅合成字节和临时目录，不读取用户照片、位置、凭据、配对数据或网络。覆盖逐字节篡改/截断、错误 key/Context、追加、重排、重放、跨归档拼接、限额、有效 MAC 但错误终帧/非规范结构、短读写、无进度、恢复原子发布、失败清理和并发同名目的地。可用 `go test -race ./internal/vault` 执行合成字节测试；跨平台编译不能代替原生验收。

Mac 原生权限、hard link 支持及断电行为仍须对应系统实测。Windows 私有 ACL 恢复实现尚未开发，当前拒绝恢复的原生测试也尚未运行；只交叉编译。跨平台编译不等于手机真机恢复或操作系统隐私验证。
