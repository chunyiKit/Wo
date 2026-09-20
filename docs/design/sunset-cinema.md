# 日落影院 · Android 改版

## 目标与视觉语言

以用户选中的 C「落日影院」概念图为基准：真实落日海岸摄影、象牙白衬线标题、酒棕黑底、琥珀色描边和层次清晰的半透感面板。首页由摄影开场、精选插件、生活章节组成，内容来自真实 bootstrap，不写死演示数据。

- 深色为新安装默认外观，浅色提供同一视觉的暖纸版本，保留已有用户主动保存的外观偏好。
- 首页全幅摄影独立于插件；插件全部可访问，保留排序、尺寸、纪念日绑定、增删能力。
- 主标题使用随 APK 内置的 Noto Serif SC；正文使用 Android 原生无衬线，保证表单与长列表可读。
- 圆角 18 / 24 / 28，间距 4 / 8 / 12 / 16 / 24 / 32；主操作最小触控高度 48。
- 动效用于卡片展开、导航选择、首屏入场与按钮反馈；尊重系统减少动画，不持续运行装饰动画。
- 成员头像使用真实上传照片和共享 MemberAvatar，失败或未上传回退 emoji。
- 刷新保留旧数据，不用整页 spinner 替换已有列表；首屏、错误、空状态统一设计。

## 交付清单

- [x] 内置摄影资源、字体及许可
- [x] 全局深浅主题、字体、按钮、输入、选择、列表、弹窗、Sheet、反馈
- [x] 首页摄影布局、真实插件预览、编辑与导航
- [x] 启动、引导、登录、加入家庭
- [x] 消息、个人、设置、外观、家庭、插件市场
- [x] 插件：记账、纪念日、家务、囤货、菜谱、回忆、电影、家历、订阅、植物、退休、到期、旅行、宠物、家聊
- [x] 页面状态与头像约束审查、手机窄屏与大字验证
- [x] flutter analyze、全部测试、Android 模拟器视觉及交互验证
- [x] 同签名 release APK、dry-run、正式发布及远端版本/hash 验证

## 资源

- 摄影：通过内置 ImageGen 根据用户批准的 C「日落影院」概念图生成。
  - 原始输出：`/Users/chunyi/.codex/generated_images/01a07207-e8f4-7741-9627-98b0e0ee9894/exec-d1f2b9a8-f50a-4780-b22f-af4bc668fdfb.png`。
  - 参考图：同目录 `exec-087bf02f-acfa-49d7-980b-9def70b79b11.png`。
  - 生成要求：竖幅电影感海岸日落摄影，琥珀太阳位于右上方、酒棕色天空与海面、远山、暗色前景，右下方两位匿名人物背影；左侧留出标题空间；不含文字、界面、手机框。正式资源为 `assets/images/sunset-cinema.png`。
- 字体：[Google Fonts / Noto Serif SC](https://github.com/google/fonts/tree/main/ofl/notoserifsc)，SIL OFL 1.1，许可随资源保存。

## 验证记录

2026-09-05：

- `flutter analyze --no-pub`：无问题。
- `flutter test --no-pub`：117 项全部通过；最后一处到期页图标调整后，另行通过该页深浅主题 2 项检查。
- 37 个实际页面及表单分别在影院 320dp、暖纸 360dp、字体放大 1.3 倍下验证布局，覆盖首次加载、非空列表、空状态、错误组件和滚动后布局。
- 对比度检查覆盖深浅主题的正文、次要文案与主按钮前景，均达到 4.5:1。
- Android 14 / Pixel 8 模拟器：复查首页、消息、个人、插件市场、家庭、外观和 15 个插件；原始截图存于 `build/cinema-qa/screen-*.png`。测试使用本地示例家庭与业务数据，调用的是实际 Flutter 页面与路由，未写入线上数据。
- 本地验收入口 `tool/cinema_preview.dart` 与 fixture 位于生产入口之外；正式构建明确使用 `lib/main.dart`，继续调用原有真实后端。
- 动效包含首页 650ms 入场、卡片 130ms 按压、480ms 展开、导航 380ms 选中位移、Sheet 420ms 入场；系统减少动画时关闭相关过渡。
- 示例动效录屏：`build/cinema-qa/wo-cinema-demo.mp4`（Android 软件渲染调试环境；仅展示交互过程，不作为真机帧率评测）。
- 正式入口构建 APK 成功（49.4 MB），Android 14 模拟器 `adb install -r` 覆盖安装成功，`firstInstallTime` 保持原值，包名 `io.github.chunyikit.wo`、版本名 `2.1.0`、版本号 `50`，架构 `arm64-v8a`。
- 新旧 APK 的签名证书 SHA-256 一致：`88b5f0244cca2275487488e8f521348ad1d69e9fa402af586d26948a3ec7c5cd`。
- 正式 APK 的摄影引导、分页、跳过进入登录、输入焦点及键盘展开均已检查，AndroidRuntime / Flutter 错误日志为空。截图 `release-start.png`、`release-login.png`、`release-keyboard-settled.png`；正式版引导录屏 `wo-release-intro.mp4`。
- 发布脚本 dry-run 与正式发布均成功，2026-09-05 23:27（北京时间）上线 `2.1.0+50`。线上版本 API 已核对版本、大小与 SHA-256，下载地址 HTTP 200，Content-Length 一致。
- 正式 APK SHA-256：`f25ac3dfcba364910f08272950797f2c3077bada3e4ff2baffd1e291893f6bb1`；大小 `49354072` 字节。证据与原始日志见 `build/cinema-qa/verification.json`、`published-version.json`、`publish.log`、`release-signature.txt`。
