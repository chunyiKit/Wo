# 本地 TLS 接收与只读管理边界

本服务只使用 Go 标准库，静态网页通过 go:embed 打包。没有旧后端、云存储或遥测调用。运行目录和 TLS/令牌状态必须放在可信本机私有目录，不能放入 Git；默认目录由 CLI 按平台选择，避开 Desktop/Documents/常见云同步目录。

## 认证

- 全部请求要求 TLS；手机客户端使用明确核对的证书 SHA256 固定，不使用环境 HTTP 代理、不跟随重定向。TLS传输私钥不是受限内容密钥。
- 网页及 /admin/* 仅接受实际 RemoteAddr loopback 和 loopback Host，忽略不可信转发头；管理码只从当前终端给本机操作员，Cookie为Secure/HttpOnly/SameSite=Strict，有效8小时。Origin存在时必须精确同源；CSP、nosniff、no-referrer、no-store生效。
- 管理员为一个明确家庭生成256bit一次配对码，5分钟有效，绑定家庭且消费后失效。手机必须同时核对电脑证书指纹；当前没有手机端二维码/NSD接线。
- 配对后设备Bearer令牌仅给手机一次，电脑磁盘只存哈希/家庭/设备ID。每个请求按令牌家庭解析，无法在URL指定别的家庭读取。撤销阻断后续请求；已在处理的请求、已复制的公开字节/密文、恢复者已掌握的密钥和明文无法收回。未实现受限内容钥轮换，不伪称吊销可擦除离线资料。

## API

- `POST /admin/session`：本机管理码换Cookie。
- `POST /admin/pair`、`GET /admin/devices`、`POST /admin/revoke`：显式配对/后续访问撤销。
- `GET /admin/backups`、`POST /admin/backups/{family}/{backup}/check`：只读列表及重新流式核验。
- `GET /admin/backups/{family}/{backup}/files/{entry}`：仅公开已校验文件；sealed恒403，无网页解密入口。
- `POST /v1/pair`：一次配对，返回家庭绑定令牌。
- `GET/POST /v1/backups`、`GET /v1/backups/{backup}`：仅令牌家庭的归档清单/创建/状态。
- `PUT /v1/backups/{backup}/entries/{entry}?offset=N`：Content-Length最多8MiB，X-Chunk-SHA256必填；最多4个并发接收块，网络读取不持全库锁。
- `POST /v1/backups/{backup}/finalize`：逐文件全文SHA及sealed固定头检查，再写验证标记；无内容钥无法认证sealed内部。
- `GET /v1/backups/{backup}/manifest`、`GET /v1/backups/{backup}/files/{entry}`：已校验归档的只读恢复，包括sealed密文；支持ETag/Range/If-Range，响应始终attachment+octet-stream+sandbox。完整接收者再次按manifest校验全文SHA，不能把Range收到部分当完成。

除offset外不接受query，令牌/管理码/内容钥禁止放URL。API错误不回传文件路径、认证或私密正文。没有删除/手机反向写入/合并接口，也不接受任意电脑源文件路径或URL抓取。

## 完整与保密的实际含义

`scope=declared_public_files` 的 complete 仅表示发送端声明的公开文件字节齐全、原件保真声明明确且最近一次全文摘要匹配；**full_device_complete始终false**，本 Go 模块未审计整机插件库存、未完成数据库导入。原件保真依据发送端权限及独立源摘要，电脑无法凭SHA证明平台没先脱敏/转码。

受限条目只接受一个不含标题/文件名的sealed容器；内部正文、缩略图、计数、成员关系和原媒体清单须先在客户端加密。电脑无内容钥，scope变为opaque_restricted_unverified且complete=false。InspectHeader只检查格式，不证明AEAD；须由恢复者在自己控制的设备上认证/解密与校验内层归档。服务端不能独立证明一个恶意发送者没有把私密内容误标为public，未来手机导出必须先做范围和权限选择；当前未接手机适配。

原件缺失/云端仅有/权限拒绝/source_exact=false均明确不完整。空通知、目录卡片或本服务接收成功均不等于手机完整版本已交付。Go恢复客户端只创建归档缓存/惰性恢复文件，不自动应用旧URI、书签、照片ID、设备身份或伴侣绑定。

验证marker表示最近校验时间；列表只检查结构/尺寸，不每次重哈希所有视频。磁盘发生同尺寸位翻转须Check或接收端全文SHA检测；下载客户端不会将坏文件发布为成功。两个进程不得同时写同一目录，CLI通过独占serve.lock防止重复服务；强杀后遗留锁需人工核对，不自动删除。

## 本轮验证

真实Linux loopback TLS TCP测试覆盖配对/重放/跨家庭/撤销/坏指纹、公开与受限网页下载隔离、恶意Origin/Host、JSON/query边界、附件型下载/CSP、TLS身份持久性；强制关闭第二块上传/下载连接，双方已确认8MiB前缀保留，再次调用后全文摘要一致。合成GPS JPEG和HDR10媒体测试可用 `WO_SYNTHETIC_FIXTURE_DIR` 启用，上传前SHA独立由Python记录。

未有手机经Wi-Fi/Private网络连入、NSD、OS局域网授权、Android原始媒体权限或Mac/Windows原生执行结果。Windows的受限明文恢复因私有ACL尚无原生守卫而明确拒绝，接收/保存密文及公开恢复可交叉编译，不能写成Windows受限恢复完成。
