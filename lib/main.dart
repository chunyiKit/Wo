import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/api_config.dart';
import 'data/push_service.dart';
import 'data/wo_http_overrides.dart';
import 'data/wo_session.dart';
import 'navigation/wo_router.dart';
import 'theme/wo_theme.dart';

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
  // 前台收到 / 点开推送时，刷新消息中心与未读角标。
  push.onInboxShouldRefresh = session.requestMessagesRefresh;
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
  // 路由表只构建一次，避免热重载时丢失导航栈。
  final _router = buildRouter();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 部分 OEM 退后台会把刷新率重置回 60Hz，回前台重申请一次。
      unawaited(_applyHighRefreshRate());
      // 从后台回到前台时刷新消息中心：推送多在后台到达，回来要能立刻看到。
      if (widget.session.isLoggedIn) widget.session.requestMessagesRefresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('en'),
          ],
          routerConfig: _router,
        ),
      ),
    );
  }
}
