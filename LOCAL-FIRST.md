# Wo 本地优先重构源码

本分支是用于评审的源码候选，不是发布版本。Android/iOS 编译、模拟器、两手机局域网互通和 Mac/Windows 原生运行尚未验证；没有 APK/IPA 发布物。

## 数据和服务边界

- Android/iOS 的家庭、插件记录、片单状态、媒体引用和生成结果以本机 SQLite / 私有文件为事实源。
- 可选天气、电影查询和用户配置的图像模型只提供相应服务；缺配置或网络不阻断普通本地记录。
- 已配对同家庭手机在同 Wi-Fi 前台发现、认证、加密并双向合并增量。回忆原照片和原视频不在手机间传输，只传授权缩略图及信息。
- Mac/Windows 电脑端为 Go 内嵌管理网页，手机主动备份原图、原视频及附件。缺件明确不完整；受限归档由恢复者持钥，电脑不自动反向覆盖手机。

## 源码入口

| 领域 | 入口 |
| --- | --- |
| 启动、本地 SQLite 与家庭 | `lib/local/local_runtime.dart`、`local_store.dart`、`local_api.dart` |
| 15 个插件目录及业务 | `lib/local/plugin_catalog.dart`、`lib/local/plugins/` |
| 配对与增量同步 | `lib/local/sync/`、`lib/features/profile/local_sync_page.dart` |
| 原件媒体与普通附件 | `lib/local/media/`、`lib/local/attachments/` |
| 手机备份与只读恢复 | `lib/local/backup/`、`lib/features/settings/` |
| 电脑端 | [CLI 用法](desktop/CLI.md)、`desktop/cmd/wo-computer/`、`desktop/internal/` |
| 原生媒体限制 | [本地媒体桥](docs/rebuild/NATIVE-MEDIA.md) |
| 隔离安装保护 | [测试工具说明](tool/rebuild/README.md) |

## 当前限制

普通 PDF/办公附件支持保存、摘要核验、同步和再备份，尚未接外部打开/导出；聊天视频、系统后台提醒、部分插件图片工作流及小票 OCR 未完成。expiry 当前仅在前台补算本机站内消息，本机开关不表示系统推送。

恢复只加入独立只读资料库，不覆盖活动库，不恢复旧设备/伴侣身份，也不解除财务历史来源校验。Windows 的电脑明文恢复因未实现私有 ACL 校验而主动关闭；接收密文和手机持钥恢复是不同能力。

其它插件同轮通知及宠物同轮完成仍有不同作者冲突；大图库/长聊天历史性能和原生权限仍需验证。配对采用逐对信任，本机撤销不能抹除对端已复制的数据，未实现全家庭密钥轮换。

## 验证入口

以下入口可供开发者复现相应测试。Python 检查是源码契约及独立 SQLite/文件模型，不替代 Dart 业务或原生执行。

```sh
python3 tool/rebuild/validate_python.py
python3 tool/rebuild/test_recovery_workspace.py
# 在 desktop 目录
go test -race ./...
go vet ./...
```

Dart/Flutter、Android/iOS 和 Mac/Windows 原生验收仍需单列记录。Android 只使用明确授权的隔离测试设备与 `io.github.chunyikit.wo.rebuild` 包；安装工具会拒绝已有相同 app ID，不卸载、不清数据、不覆盖现有 App。

## 公开提交对应关系

基础为 main `c4f089bda0b2a0b7789261c669509681bd99f040`。业务源码对应本地候选 `924377d768e0e2b25adfc8ca2b50291b364f2a13`；公开历史保留 57 个分阶段提交，另有 4 个仅开发记录的提交未纳入。生产代码和测试逻辑保持一致；差异限于不发布开发报告、示例路径及环境中性测试注释。此文件是额外的公开导读。

提交通过 GitHub Git Data 接口重建，作者使用账号的 GitHub noreply 身份，因此提交 SHA 和提交时间与原候选不同。原候选保留在本地；下表是原提交到公开提交的对应关系。

| 原提交 | 公开提交 |
| --- | --- |
| `8ec38f611a04ca3da54fe0f35d090321b361c1e1` | [`95612309abef13f8ac832db2af4fb5e3911f98ae`](https://github.com/chunyiKit/Wo/commit/95612309abef13f8ac832db2af4fb5e3911f98ae) |
| `f4007cb97fbdf476dba2df9df89ffcf2e4b55d6f` | [`9325f737c2b89648e41579fc839a7bdc70ec5fbd`](https://github.com/chunyiKit/Wo/commit/9325f737c2b89648e41579fc839a7bdc70ec5fbd) |
| `55839c8798b6d285bc4bdf68bb325644401f454e` | [`98a6f6d3f3638a54a7a7fd87d583c56716d59f71`](https://github.com/chunyiKit/Wo/commit/98a6f6d3f3638a54a7a7fd87d583c56716d59f71) |
| `23bce6eabc3fdd432a41ed2fc34b00d5061d9bc5` | [`ad10148fa9cc8752fdc4d21d7a3425eb85b07e22`](https://github.com/chunyiKit/Wo/commit/ad10148fa9cc8752fdc4d21d7a3425eb85b07e22) |
| `b3c07949dbcc719f495a78bd83e9abca8903b0ed` | [`7caba0f1536abeb03ada1679b2dd90e82bd4658e`](https://github.com/chunyiKit/Wo/commit/7caba0f1536abeb03ada1679b2dd90e82bd4658e) |
| `b24aece5de1aef9731f200ae78fc2e0e26c1cd28` | [`aa70be9e6365bf2460ae430ab797222157f411da`](https://github.com/chunyiKit/Wo/commit/aa70be9e6365bf2460ae430ab797222157f411da) |
| `daf030d77022bcb4394186d1bb6f09c31080e386` | [`84778f2aaf020b7c947fc1c958afc1c8f7e19fa7`](https://github.com/chunyiKit/Wo/commit/84778f2aaf020b7c947fc1c958afc1c8f7e19fa7) |
| `09ae2ec1d4e64b3ffd3de8c2da17eaa764caedef` | [`6364777dd101d381e184e8485630636035d8deda`](https://github.com/chunyiKit/Wo/commit/6364777dd101d381e184e8485630636035d8deda) |
| `1befe95ce2110c2ebb4b6372582caba22c842c23` | [`bb81e5513a4d07666389d9dc1bc7a6dc218fe9f6`](https://github.com/chunyiKit/Wo/commit/bb81e5513a4d07666389d9dc1bc7a6dc218fe9f6) |
| `311dc81f1639e6f6d5ce85b9932c12845dc3c250` | [`d5547b9810f766f8648d73fed3b849bed0211c4c`](https://github.com/chunyiKit/Wo/commit/d5547b9810f766f8648d73fed3b849bed0211c4c) |
| `764f035508f35e82fa38fadd686b419bde6adddd` | [`2d2f9f0e5edda5fb026a0cee5f579cb8b6dd4047`](https://github.com/chunyiKit/Wo/commit/2d2f9f0e5edda5fb026a0cee5f579cb8b6dd4047) |
| `5d07530a0c8b08ca91e03f0f7a1b8bd6d9e900a0` | [`33dc1673a4a0fca0c8672aa8c8c8ac807819511e`](https://github.com/chunyiKit/Wo/commit/33dc1673a4a0fca0c8672aa8c8c8ac807819511e) |
| `39de121dee721faa67f3f1eb8f7783ea0884eae2` | [`189c8a14c44df6ae4d07ce709c363a913029be53`](https://github.com/chunyiKit/Wo/commit/189c8a14c44df6ae4d07ce709c363a913029be53) |
| `5e21b7eb0f580ccb03d1de3bc9ff5c1975c7fcda` | [`24fb4ec509dbcead2ffd58367024e83904d734a3`](https://github.com/chunyiKit/Wo/commit/24fb4ec509dbcead2ffd58367024e83904d734a3) |
| `a7bde8ddcb86c26f9c48ff24dc6711d47b93e5c0` | [`8c8c66905e0fd92a55b24216a9703e86b1b2d920`](https://github.com/chunyiKit/Wo/commit/8c8c66905e0fd92a55b24216a9703e86b1b2d920) |
| `c76272d8ac55fa307b69e9fcff8ea3d4a6490b8a` | [`ff2e4de21e6a6cacc9f2b45ed429e9044434f484`](https://github.com/chunyiKit/Wo/commit/ff2e4de21e6a6cacc9f2b45ed429e9044434f484) |
| `b5c10ccca985a900ddf9b40001f5d3f6734d3eef` | [`ecfc8794acc988edae01396922e8c49f5b63b7e2`](https://github.com/chunyiKit/Wo/commit/ecfc8794acc988edae01396922e8c49f5b63b7e2) |
| `90f64cec1b5444b194bb820a1171e2bb5aa259f9` | [`5d77490b7673f1c5ed8f9eb698b88771cf39ce41`](https://github.com/chunyiKit/Wo/commit/5d77490b7673f1c5ed8f9eb698b88771cf39ce41) |
| `eedd3c1def9135c7b759bc38d95b81c82f40471a` | [`61bfb3e81b8bf8809bd03dd2f610e6b366c6f7b6`](https://github.com/chunyiKit/Wo/commit/61bfb3e81b8bf8809bd03dd2f610e6b366c6f7b6) |
| `5adcb91c53eb2fc3f0113abbe6f01e4f8338be65` | [`f1aa589c6ee46247eaddc9946eb1c1fc63e770a0`](https://github.com/chunyiKit/Wo/commit/f1aa589c6ee46247eaddc9946eb1c1fc63e770a0) |
| `6fff29e1bfa94a24089c8a09504bb3e1424764e1` | [`267cac5afbe536b5c2273e2264d70206a36bcca7`](https://github.com/chunyiKit/Wo/commit/267cac5afbe536b5c2273e2264d70206a36bcca7) |
| `e8ef685c216c2f3df68c7149f108b36026950b51` | [`e6ac1d0c689a077873331c2bb8de7d519c9d23c6`](https://github.com/chunyiKit/Wo/commit/e6ac1d0c689a077873331c2bb8de7d519c9d23c6) |
| `372d51b2c79ac841f4572febb444ed1450b75ae5` | [`d7be8b5ffaf1c67c327fcd1ac4ef98ccb3097b9f`](https://github.com/chunyiKit/Wo/commit/d7be8b5ffaf1c67c327fcd1ac4ef98ccb3097b9f) |
| `a53d41d0da3f0501aeadf3afa9c1bf3d34f87131` | [`8e078d692b8d244bb5622dd41985596855d1c379`](https://github.com/chunyiKit/Wo/commit/8e078d692b8d244bb5622dd41985596855d1c379) |
| `98cc57f250711973dee37e83fc9b95f5fe0b21e0` | [`a60562c40b50cc498e2d84aa230f16fa9a641f62`](https://github.com/chunyiKit/Wo/commit/a60562c40b50cc498e2d84aa230f16fa9a641f62) |
| `c7a51eafa4d0de66137d6ca2350307ff306f6f1c` | [`3a487500fd444d1b4987574a8a1204f8f10f2644`](https://github.com/chunyiKit/Wo/commit/3a487500fd444d1b4987574a8a1204f8f10f2644) |
| `965304080c62c07659c025008a71ac8e258c7ba1` | [`ae3735692f922079b50c0d4ab0917a6b5784911c`](https://github.com/chunyiKit/Wo/commit/ae3735692f922079b50c0d4ab0917a6b5784911c) |
| `b6f30b3d5f2a1a5300314c483eb84c80c79391e5` | [`a0a7ceab1b36c988cb3b26c5913fc5118cec32af`](https://github.com/chunyiKit/Wo/commit/a0a7ceab1b36c988cb3b26c5913fc5118cec32af) |
| `9f7c2fedbab38764c21167cc972d86dd9c04358d` | [`851ae88817cb3694ec6eae626d5940a85186474d`](https://github.com/chunyiKit/Wo/commit/851ae88817cb3694ec6eae626d5940a85186474d) |
| `b8c05d60760a7dde49311d086370eb50ef43c156` | [`e1b8b7dd0fee70950534b9bc4c9425791b62c28e`](https://github.com/chunyiKit/Wo/commit/e1b8b7dd0fee70950534b9bc4c9425791b62c28e) |
| `fe7026c0cf2237c588795a67c1d33ca945fa3f4d` | [`ef1ad65f10f8348c833d3b5fb5e553dee883b1f0`](https://github.com/chunyiKit/Wo/commit/ef1ad65f10f8348c833d3b5fb5e553dee883b1f0) |
| `74f4b37f8e996fae2e10862d4181b100524efa58` | [`ee23bda70c7a64063c5308679b1f5c25e034d5ce`](https://github.com/chunyiKit/Wo/commit/ee23bda70c7a64063c5308679b1f5c25e034d5ce) |
| `4dc2c34207625203b1e1a3d968129365461e6cea` | [`9de0e135da85d4d619f02710562d8ea7834366f5`](https://github.com/chunyiKit/Wo/commit/9de0e135da85d4d619f02710562d8ea7834366f5) |
| `065d85bb923a306c664e325ebf463ec0c61d0843` | [`b22d78b63ac517bdd46847b03db117d08550480a`](https://github.com/chunyiKit/Wo/commit/b22d78b63ac517bdd46847b03db117d08550480a) |
| `6412c42b5b2725d25852575a05f19ca677ba00a1` | [`0c2f9b01c4b3c69d331d896b99241e40e6642254`](https://github.com/chunyiKit/Wo/commit/0c2f9b01c4b3c69d331d896b99241e40e6642254) |
| `71aff924e3c7b44c764d08812d075a9e2cc64ee8` | [`461a5ef237752ef7c93d1d9c29215feb7c026aeb`](https://github.com/chunyiKit/Wo/commit/461a5ef237752ef7c93d1d9c29215feb7c026aeb) |
| `7e813f2a0bec7c41e14175a63c6e5b7d268a5f1b` | [`95f3aa5583eafac5738c351816f43b7c0f108c31`](https://github.com/chunyiKit/Wo/commit/95f3aa5583eafac5738c351816f43b7c0f108c31) |
| `00067da985e43c21dcc68a081d45d2d6df655928` | [`d0e914e550a227d93d2ae037a173aece3b58e6dd`](https://github.com/chunyiKit/Wo/commit/d0e914e550a227d93d2ae037a173aece3b58e6dd) |
| `2485700f5f04df14ed0f4308021b492f231e9c13` | [`52cf72a555b7801426c60f966f34d32f8c73a4af`](https://github.com/chunyiKit/Wo/commit/52cf72a555b7801426c60f966f34d32f8c73a4af) |
| `f9fadb53b03120a3768bc664879e2ba618b0212d` | [`9572b18e0bfec03a4f1b77a063971c509a2280f3`](https://github.com/chunyiKit/Wo/commit/9572b18e0bfec03a4f1b77a063971c509a2280f3) |
| `41ab195d6459fb92fbeee2690de580b0b7be64ef` | [`abc99e7a3ac307c724733f839f08b8f30def90c4`](https://github.com/chunyiKit/Wo/commit/abc99e7a3ac307c724733f839f08b8f30def90c4) |
| `0efa862e62457647236c3dfdbdba2118555c50e6` | [`0d49192f1cea6492a9a89d296ba8e23c0972e6cd`](https://github.com/chunyiKit/Wo/commit/0d49192f1cea6492a9a89d296ba8e23c0972e6cd) |
| `eb25b7e823c03b30a9b025cdc067379461f94af1` | [`8f18bb4c09b3a785172e9df808bb12ee5f8c857e`](https://github.com/chunyiKit/Wo/commit/8f18bb4c09b3a785172e9df808bb12ee5f8c857e) |
| `4d00487ea33c7c2c0342f72bc63f0925f4b7c5ae` | [`065469fa72ef510604d9ad7482aa190a9289a95d`](https://github.com/chunyiKit/Wo/commit/065469fa72ef510604d9ad7482aa190a9289a95d) |
| `e1a37ce9494a881e694406ca4f2e49bb2c19b7d0` | [`09f028e169e30f3f2cada5e5b06d23dbc1b37549`](https://github.com/chunyiKit/Wo/commit/09f028e169e30f3f2cada5e5b06d23dbc1b37549) |
| `494fe74774814d525e221d2fc731393a11ee5383` | [`bd7edeaf0783643f2833d833b92eb37505a0a06c`](https://github.com/chunyiKit/Wo/commit/bd7edeaf0783643f2833d833b92eb37505a0a06c) |
| `f419da79aefc622d1e50433315d2a287cd6f3575` | [`71d4d2b9cb9a7b91a85de2c26204b706b2223e51`](https://github.com/chunyiKit/Wo/commit/71d4d2b9cb9a7b91a85de2c26204b706b2223e51) |
| `820e2055b151df85fc8107a1c65f7e3e87dd2303` | [`8d764231e13d06adf9574e562cb8ad0815c2a2ea`](https://github.com/chunyiKit/Wo/commit/8d764231e13d06adf9574e562cb8ad0815c2a2ea) |
| `705bcebfe24d22fca6cc4e5da8b3dd2bcefbf5e7` | [`322a3065305fce5d9fc0642af76d65a0476c5ebd`](https://github.com/chunyiKit/Wo/commit/322a3065305fce5d9fc0642af76d65a0476c5ebd) |
| `4ffb7d2fcc6b9b95797fb82c14e9b7a5a34b7f99` | [`db4e36869c9c02de0ea090f2721d864c95b4e8a0`](https://github.com/chunyiKit/Wo/commit/db4e36869c9c02de0ea090f2721d864c95b4e8a0) |
| `c49707b6f31e45f553af40642649d01091077a5b` | [`7b235f107651faf20130c84d4f3a8c98bdb45267`](https://github.com/chunyiKit/Wo/commit/7b235f107651faf20130c84d4f3a8c98bdb45267) |
| `948a55090242bab269e7542459add74209337eec` | [`51f1d1120ebb0f1523836d5a27da3715ed3d122e`](https://github.com/chunyiKit/Wo/commit/51f1d1120ebb0f1523836d5a27da3715ed3d122e) |
| `35535bb138ac310267174f60ef8bee36ad880576` | [`561cb74c6ccf861bad42bed0d75448a2a6dfef36`](https://github.com/chunyiKit/Wo/commit/561cb74c6ccf861bad42bed0d75448a2a6dfef36) |
| `37baa6584f5ed215325bb727b84cba26a49b220f` | [`f920f3bb609380795d9796ed9f40a28bbb13979c`](https://github.com/chunyiKit/Wo/commit/f920f3bb609380795d9796ed9f40a28bbb13979c) |
| `eeba4b94b5a2bd0dd9f1501f89c79fdd03fb844b` | [`29ef28a3061d26f20a0c0dc78595ffb26f594d77`](https://github.com/chunyiKit/Wo/commit/29ef28a3061d26f20a0c0dc78595ffb26f594d77) |
| `f7b5a6ae90b4d3d0f1250cf4638dfcb3c65bcf73` | [`51f3557358d336ce8097cd0fcdf5364c638502fe`](https://github.com/chunyiKit/Wo/commit/51f3557358d336ce8097cd0fcdf5364c638502fe) |
| `7503a54828901670298a7288d5b4e26b6756b225` | [`12bb9bb2e798c3e8824ca20d82f6ffccbd0ff773`](https://github.com/chunyiKit/Wo/commit/12bb9bb2e798c3e8824ca20d82f6ffccbd0ff773) |
