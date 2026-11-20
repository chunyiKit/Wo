# 重建模块检查点与安全安装入口

这些工具只处理本地源码或明确指定的测试设备，不上传、不推送、不启动模拟器。工具测试使用临时 Git 仓库和模拟 ADB，不代表 Android 真机运行。

## 每个模块 commit 后保存

从仓库根目录执行，输出必须是仓库外的全新目录：

```sh
python3 tool/rebuild/checkpoint.py \
  --out /path/to/local-checkpoints/模块名-提交短SHA \
  --base c4f089bda0b2a0b7789261c669509681bd99f040
```

默认只读取当前**本地分支已提交对象**。未跟踪文件、工作区改动、`.git/config`、credential helper 配置均不进入产物。按 Git 内容而非工作目录归档，运行时配对数据、密钥和数据库必须继续留在被忽略的目录，不能先提交再指望打包工具擦除。

工具检查可疑凭据文件、私钥内容和凭据形状的长字符串，包括提交消息；输出风险路径/原因，不输出值。这是保守的泄漏防护，不能取代代码审查，也不保证识别一切未知格式秘密。

- 全历史扫描通过：生成 `source.bundle`、记录 SHA/字节、执行 `git bundle verify`，再从 bundle 临时 clone，核对精确 HEAD 和 tree，并运行 `git fsck`。这是可独立恢复的当前分支源码历史。
- 基础历史被拒绝但新增提交安全：生成 `module.patch`；明确依赖 `--base` 完整 SHA，临时 checkout 该基础、真实 `git am`，比较最终 tree。此模式只保证代码 tree 恢复，**不声称恢复了原始提交 SHA 或独立完整历史**。拿到原始基础仓库后才能恢复；恢复后的 committer 元数据可能改变 SHA。
- 新增对象或补丁也有风险：拒绝输出源码产物，不静默删改提交。只留下不包含凭据值的拒绝报告。
- HEAD 等于 base 且基础整包扫描被拒绝：只写基础定位记录，CLI 退出 **3**；没有源码备份，不能算已完成检查点。

成功必须以 `manifest.json` 中 `restored_tree_verified=true` 和产物 SHA 为准，不能只看文件存在。不要覆盖之前的检查点。

恢复完整 bundle：

```sh
git bundle verify /备份目录/source.bundle
git clone --branch feat/wo-local-first-rebuild /备份目录/source.bundle 恢复目录
```

恢复 patch（先从授权来源取得明确基础仓库）：

```sh
git checkout --detach c4f089bda0b2a0b7789261c669509681bd99f040
git am /备份目录/module.patch
# 对照 manifest 所记录的来源 tree/提交信息，再创建需要的本地分支。
```

**同一云机/共享目录上的 bundle 或 patch 只是本地冗余，不代表已跨故障域保存。** 是否另存到明确持久目的地由用户授权决定，本工具不会自动上传。

## APK 先验身份，再安装隔离包

先只读检查，不连接任何设备：

```sh
python3 tool/rebuild/android_install.py --inspect-only \
  --apk 测试.apk --aapt /SDK/build-tools/版本/aapt \
  --apksigner /SDK/build-tools/版本/apksigner --out /本地目录/apk-inspection.json
```

检查结果包括实际 app ID、APK SHA、签名证书 DN 和 **SHA-256 指纹**；只写 "Android Debug" 不能唯一识别证书。

安装入口仅接受 `io.github.chunyikit.wo.rebuild` 或其子包名，拒绝原生产包名；构建时应配置隔离 applicationIdSuffix。默认不启动：

```sh
python3 tool/rebuild/android_install.py \
  --apk 测试.apk --serial 明确测试序列号 --confirm-test-device \
  --adb /SDK/platform-tools/adb --aapt /SDK/build-tools/版本/aapt \
  --apksigner /SDK/build-tools/版本/apksigner \
  --out /本地目录/install-result.json
```

- 必须明确序列号，不能自动选择第一台设备。
- 查询所有可见 Android 用户的目标包；相同 app ID 已安装或保留数据时，**直接拒绝**。无法核对所有用户也拒绝。
- 安装没有覆盖、降级或自动授权参数。没有卸载、`pm clear`、重装补救或自动重试路径。不要执行旧版本验收脚本的清库命令。
- APK 先验签，再复制到私有临时目录核对 SHA；只安装该核对副本。
- `--launch` 只在新隔离包安装成功后按实际 Activity 启动；不自动点击授权弹窗。安装或启动成功不等于首页、离线业务或 NSD 已验收。
- 超时记录为结果未确定，先只读查询，不自动重试或清理。实际应用/用户资料不在测试允许的破坏范围内。

原生验收需使用明确授权的隔离测试设备；工具模拟不代表设备运行。
