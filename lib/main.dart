import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/api_config.dart';
import 'data/app_update.dart';
import 'data/push_service.dart';
import 'data/wo_http_overrides.dart';
import 'data/wo_session.dart';
import 'navigation/notification_nav.dart';
import 'navigation/wo_router.dart';
import 'theme/wo_theme.dart';
import 'widgets/app_update_dialog.dart';
import 'widgets/wo_material_controls.dart';

/// 申请 Android 高刷新率：Flutter 默认把渲染锁在 60fps，即便屏幕是 90/120Hz，
/// 动画就会偏卡。这里请求当前分辨率下的最高刷新率；不支持高刷 / 取模式失败都忽略，
/// 维持系统默认。部分 OEM 在退后台后会重置，故回到前台时还会再申请一次。
Future<void> _applyHighRefreshRate() async {
  if (!Platform.isAndroid) return;
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (_) {
    // 忽略：维持默认刷新率。
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['Noto Serif SC'],
      await rootBundle.loadString('assets/fonts/OFL-NotoSerifSC.txt'),
    );
  });
  // 尽早申请高刷新率，让首帧起就跑满屏幕刷新率。
  await _applyHighRefreshRate();
  // 信任内置私有 CA(裸 IP + 自签证书的 HTTPS)。必须在任何网络请求前装好。
  HttpOverrides.global = await WoHttpOverrides.load();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
  );

  // 极光推送：初始化 SDK + 申请通知权限（后台进行，不阻塞首帧）。registration
  // id 的上报由 WoSession 在登录/启动时完成。
  final push = PushService(
    appKey: ApiConfig.jpushAppKey,
    channel: ApiConfig.jpushChannel,
  );
  final session = WoSession(push: push);
  // 前台收到 / 点开推送时，刷新消息中心与聊天同步信号。
  push.onInboxShouldRefresh = () {
    session.requestMessagesRefresh();
    session.requestChatRefresh();
  };
  unawaited(push.init());

  // 先读出外观偏好，确保首帧就用对主题（不闪）。
  await session.loadThemeMode();

  runApp(WoApp(session: session));
}

class WoApp extends StatefulWidget {
  const WoApp({super.key, required this.session});

  final WoSession session;

  @override
  State<WoApp> createState() => _WoAppState();
}

class _WoAppState extends State<WoApp> with WidgetsBindingObserver {
  final _rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'wo-root');
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  late final _router = buildRouter(
    rootNavigatorKey: _rootNavigatorKey,
    onStartupReady: _onStartupReady,
  );

  Future<void>? _launchUpdateCheck;
  bool _startupReadyHandled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session.push?.onOpenNotification = _openPushTarget;
    // APK 应用内更新仅适用于 Android。检查与启动数据并行，不阻塞 Splash；
    // 弹窗会等 Splash 完成导航后再显示，避免被路由替换带走。
    if (Platform.isAndroid) {
      _launchUpdateCheck = widget.session.appUpdate.check();
    }
  }

  void _onStartupReady() {
    if (_startupReadyHandled) return;
    _startupReadyHandled = true;
    unawaited(_showLaunchUpdateIfAvailable());
  }

  Future<void> _showLaunchUpdateIfAvailable() async {
    final check = _launchUpdateCheck;
    if (check == null) return;
    await check;
    if (!mounted) return;

    final controller = widget.session.appUpdate;
    final release = controller.release;
    if (controller.phase != AppUpdatePhase.available || release == null) return;

    final dialogContext = _rootNavigatorKey.currentContext;
    if (dialogContext == null || !dialogContext.mounted) return;
    final updateNow = await showWoDialog<bool>(
      context: dialogContext,
      useRootNavigator: true,
      builder: (_) => AppUpdateDialog(release: release),
    );
    if (updateNow == true && mounted) {
      unawaited(_downloadAndInstallUpdate(controller));
    }
  }

  Future<void> _downloadAndInstallUpdate(AppUpdateController controller) async {
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(WoSnackBar(content: Text('已开始后台下载，完成后将自动打开安装页面')));
    await controller.downloadAndInstall();
    if (!mounted || controller.message == null) return;
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(WoSnackBar(content: Text(controller.message!)));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 部分 OEM 退后台会把刷新率重置回 60Hz，回前台重申请一次。
      unawaited(_applyHighRefreshRate());
      // 从后台回到前台时刷新消息中心：推送多在后台到达，回来要能立刻看到。
      if (widget.session.isLoggedIn) {
        widget.session.requestMessagesRefresh();
        widget.session.requestChatRefresh();
      }
    }
  }

  void _openPushTarget(Map<String, dynamic> event) {
    final deeplink = _deeplinkFromPush(event);
    if (deeplink == null || deeplink.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(openDeeplinkTarget(context, deeplink));
    });
  }

  String? _deeplinkFromPush(Map<String, dynamic> event) {
    final direct = event['deeplink'];
    if (direct is String) return direct;
    final extras = event['extras'];
    if (extras is Map && extras['deeplink'] is String) {
      return extras['deeplink'] as String;
    }
    if (extras is String) {
      try {
        final decoded = jsonDecode(extras);
        if (decoded is Map && decoded['deeplink'] is String) {
          return decoded['deeplink'] as String;
        }
      } catch (_) {}
    }
    return null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.push?.onOpenNotification = null;
    widget.session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WoScope(
      session: widget.session,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: widget.session.themeMode,
        builder: (context, mode, _) => MaterialApp.router(
          scaffoldMessengerKey: _messengerKey,
          title: '窝',
          debugShowCheckedModeBanner: false,
          theme: WoTheme.light(),
          darkTheme: WoTheme.dark(),
          themeMode: mode,
          // 全 App 走简体中文：日期选择器月份/星期、确定/取消等系统组件文案
          // 都用中文（默认会回退到英文）。本 App 仅面向中文用户，直接锁定 zh_CN。
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          routerConfig: _router,
        ),
      ),
    );
  }
}
