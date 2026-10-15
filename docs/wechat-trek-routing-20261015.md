# trek API 路由变更记录

完成时间：2026-10-15 12:46 UTC。用户另行明确批准：备份并仅修改 `trek` 的 Nginx API 接入，检查通过后 reload；保留旧 Android IP/default 入口、证书和路由。不包括后端部署、迁移、AppSecret 或 PR 合并。

## 实际变更

通过仓库既有 `ubuntu` SSH 通道（BatchMode、严格主机指纹校验）确认实际监听和配置后，仅修改 `/etc/nginx/sites-available/trek.chunyi-work.online`。现有启用链接仍为 `/etc/nginx/sites-enabled/trek.chunyi-work.online`，没有新增或重复的 server_name。

在原 HTTPS server 中增加三个 API location，复用现有 `wo_backend` upstream（`127.0.0.1:8000`），保留 URI 与必要代理头：

- `/api/v1/`：25 MB 请求体，60 秒读写超时。
- 回忆 API：110 MB 请求体，300 秒读写超时，保留 Flutter 视频兼容语义。
- `/api/v1/app/`：210 MB 请求体，600 秒读写超时，保留现有 APK 相关 API 兼容语义；本次没有上传 APK。

新片段仅在 443 生效；原 server 同时监听 8443，新增 API 在该备用端口返回 404，避免额外开放 Wo API。原 80/ACME、443/8443 listen、证书和续期规则、`/ws`、`/mcp`、`/` 及旧 Android default vhost 均保留。根路径仍为旧服务的 502，这是保留原路由的结果，不表示新增 API 健康失败。

## 备份和回滚

当前成功变更的 root 私有备份目录（0700）：

`/var/backups/wo-nginx/trek-api-20261015T124627Z`

包含 `original.conf`、`manifest.json`、`rollback.py`（0600）。原配置和预期新配置有 SHA-256 守卫。未来若获准回滚，可在同一既有 SSH 通道运行：

```sh
sudo python3 /var/backups/wo-nginx/trek-api-20261015T124627Z/rollback.py
```

脚本只恢复本次 trek 文件、执行 `nginx -t` 并 reload；如果文件已被其他人改成第三种版本，会拒绝覆盖，要求重新审查。此命令未在成功后执行。

第一次尝试已自动回滚，备份仍保留在 `/var/backups/wo-nginx/trek-api-20261015T124340Z`。当时 `nginx -t`、reload 成功，但立即发出的探测由旧 worker 转发到旧 3000 上游而得到 502。检查日志及 reload 的实际执行方式后，加入新 worker 就绪等待，再执行相同配置增量。Nginx 的 reload 是平滑 worker 切换，命令返回与新 worker 接管并不等价，参见 [官方说明](https://nginx.org/en/docs/control.html)。第二次验证全部通过，没有继续扩大范围或猜测修改其他配置。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| `nginx -t` | 变更前后均通过，最终再次通过 |
| reload | 成功；确认新 worker 出现，master 未重启 |
| `https://trek.chunyi-work.online/api/v1/health` | HTTP 200，系统信任验证通过，`data.status=ok` |
| `https://trek.chunyi-work.online/api/v1/app/version` | HTTP 200，系统信任验证通过，公开版本 `2.1.6+56` |
| 旧 Android IP health/version | 使用仓库原 CA 严格校验，两者均 HTTP 200，版本仍 `2.1.6+56` |
| `https://trek.chunyi-work.online:8443/api/v1/health` | HTTP 404，TLS 验证通过，未在备用端口开放 Wo API |
| trek DNS | A 记录未变，未修改 DNS |
| 配置范围 | 去掉新增 API 片段后与备份原文件逐字一致 |
| 旧 Wo 配置和两套公开证书 | SHA-256 变更前后相同 |

配置核验：

- trek 变更前：`4e0a0ffc85f031fca82060f0f647e694f7654836900b0e4d66760eee51a8dd88`
- trek 变更后：`dda1d081def8f5b7a1084febc185d0d9587ac8e1e58c74042c4b7565809f72ad`
- 旧 Wo 配置：`bff1997d164c488db78d058426ff3def5c029c92009216baddb840a58cb3f47d`

没有绕过 TLS，没有访问家庭接口、应用环境或密钥文件。公开证书只做完整性核验，私钥未读取或复制。AppSecret 未触碰，Wo 服务未重启，PR 后端没有部署，数据库没有迁移，PR 没有合并。

## 尚未上线

这次仅让域名 API 路由接到现有 Wo 服务。微信 identity migration、新版后端鉴权下载及其他 PR 能力仍需后续审核合并和单独授权部署；真实 code 交换、微信后台合法域名/类目/隐私指引、测试身份和真机上传尚未联调。小程序 `connectionReady:false` 保持关闭。移动端同步旧记录的前置版本、家聊 SQLite/图片/私人草稿迁移也未执行。
