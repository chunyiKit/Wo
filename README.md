# 窝（Wo）· Android App 骨架

「窝」是一款面向年轻小家庭（夫妻 / 情侣 / 三口之家）的**插件化**家庭事务 App。
所有功能（日程、记账、相册、清单等）以插件形式存在，按需启用。

这里是 **Flutter + Material 3** 的 Android 端骨架工程：完整的设计系统、导航
栈、底 Tab、所有主要页面都已就位。原始 Web 设计稿在 [`design/`](./design/index.html)。

## 项目结构

```
lib/
├── main.dart                       # 入口 + MaterialApp.router
├── theme/
│   ├── wo_tokens.dart              # 颜色/圆角/间距/阴影 token + WoColors 扩展
│   ├── wo_typography.dart          # 字体、字号、字重
│   └── wo_theme.dart               # Material 3 ThemeData（浅/深双套）
├── navigation/
│   ├── wo_routes.dart              # 路由路径常量
│   └── wo_router.dart              # go_router 路由表（StatefulShellRoute）
├── shell/
│   └── wo_shell.dart               # 底 Tab 主壳子
├── widgets/
│   ├── wo_card.dart                # 圆角 22 + 暖色阴影卡片
│   └── placeholder_screen.dart     # 友好空状态
└── features/
    ├── splash/                     # 启动页
    ├── onboarding/                 # 3 屏引导（家 → 插件 → 多家庭）
    ├── join/                       # 加入 / 创建家庭
    │   ├── join_landing_page.dart  # 入口选择
    │   ├── join_by_code_page.dart  # WO-XXXX-XXXX 输入
    │   ├── scan_page.dart          # 扫码（始终深色 + 暖橙识别框）
    │   └── create_family_page.dart # 创建新家
    ├── home/                       # 家庭首页（含家庭切换 + 添加插件 Sheet）
    ├── messages/                   # 消息 Tab
    ├── marketplace/                # 插件市场 + 详情
    ├── family/                     # 家庭管理 + 邀请
    └── profile/                    # 我的 + 设置
design/
└── ...                              # 原 Web 设计稿（jsx/html/css，浏览器可直接打开）
```

## 设计系统（已锁定）

| 项目 | 浅色 | 深色 |
|------|------|------|
| 主色（暖橙 / 焦糖） | `#E8895A` | `#F09A6E` |
| 背景 | `#FBF7F1`（米白） | `#15120F` |
| 卡片 | `#FFFFFF` | `#221F1B` |
| 主字色 | `#2A2722` | `#F2EDE5` |
| 卡片圆角 | 22px | 22px |
| FAB 圆角 | 18px | 18px |
| 字体 | HarmonyOS Sans + Inter（数字）+ PingFang/Noto Sans SC 回退 | 同 |

所有 token 在 `lib/theme/wo_tokens.dart`，通过 `ThemeExtension<WoColors>` 注入；
业务里 `context.wo.accent`、`context.wo.bg` 即可拿到。

## 快速开始

### 1. 安装 Flutter SDK

```bash
# macOS / brew
brew install --cask flutter
flutter doctor
```

### 2. 生成平台目录

本仓库目前只包含 `lib/` 和 `pubspec.yaml`。补全 Android / iOS 平台
工件：

```bash
cd /Users/chunyi/Wo
flutter create . --org app.wo --project-name wo --platforms=android,ios
flutter pub get
```

> `flutter create .` 在已存在的目录上跑会**保留** `lib/`、`pubspec.yaml`、
> `.gitignore` 等已有文件，只补充 `android/`、`ios/`、`test/`、平台
> 入口等缺失部分。

### 3. 运行

```bash
# 选择设备
flutter devices

# Android
flutter run -d <emulator-id>

# 调试 / Release
flutter run --debug
flutter build apk --release
```

### 4. 静态检查

```bash
flutter analyze
dart format lib/
```

## 路由 & 导航

应用启动后：

```
SplashPage  →  OnboardingPage (3 屏)  →  JoinLandingPage
                                           ├─ JoinByCodePage  →  Home
                                           ├─ ScanPage        →  Home
                                           └─ CreateFamilyPage →  Home

Home (Shell + 3 Tab)
├─ 首页   (HomePage)
│  ├─ MarketplacePage  → PluginDetailPage
│  └─ FamilyManagePage → FamilyInvitePage
├─ 消息   (MessagesPage)
└─ 我的   (ProfilePage)
    └─ SettingsPage
```

底 Tab 使用 `StatefulShellRoute.indexedStack`：每个 Tab 各自保持
navigator 栈和状态，切换不丢页面。

## 关键交互

实现状态对照原设计稿：

- ✅ **底 Tab 导航**（首页 / 消息 / 我的）
- ✅ **家庭切换下拉**：首页顶部点家名 → `_FamilySwitcherSheet`
- ✅ **添加插件半屏 Sheet**：FAB 「+」 → `_AddPluginSheet` (72% 屏高)
- ✅ **长按编辑卡片**：长按 0.5s 进入编辑态，左上角出现 `−` 按钮
- ✅ **3 屏 onboarding**：PageView + 进度条 + 跳过
- ✅ **邀请码分段输入**：WO-XXXX-XXXX
- ✅ **扫码页固定深色**：暖橙四角识别框
- ✅ **深 / 浅模式自动适配**（`ThemeMode.system`）

待真实数据/业务实现：相机扫码（需集成 `mobile_scanner`）、各插件的具体业务、
长按拖拽 reorder 抖动动画、撤销 snackbar。

## 字体（可选）

工程默认走 `HarmonyOS Sans` → `PingFang SC` → `Noto Sans SC` → 系统的回退链，
没有捆绑字体文件时会自动使用系统中文字体。
要捆绑 HarmonyOS Sans 或 Inter：

1. 把 `.ttf` 放到 `assets/fonts/`
2. 在 `pubspec.yaml` 的 `flutter:` 段下加：

```yaml
flutter:
  fonts:
    - family: HarmonyOS Sans
      fonts:
        - asset: assets/fonts/HarmonyOS_Sans_SC_Regular.ttf
        - asset: assets/fonts/HarmonyOS_Sans_SC_Medium.ttf
          weight: 500
        - asset: assets/fonts/HarmonyOS_Sans_SC_Bold.ttf
          weight: 700
```

## 设计稿浏览

`design/index.html` 是原 React + Babel UMD 的 Design Canvas，
含 23+ 张画板（onboarding / 三方向首页 / 插件市场 / 家庭管理 / 我的 /
加入创建 / 半屏 Sheet / 空状态）。

浏览器直接打开即可，或起一个静态服务器：

```bash
cd design
python3 -m http.server 8000
# → http://localhost:8000
```
