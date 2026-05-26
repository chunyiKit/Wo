import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/api_config.dart';
import 'data/push_service.dart';
import 'data/wo_http_overrides.dart';
import 'data/wo_session.dart';
import 'navigation/wo_router.dart';
import 'theme/wo_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    // 从后台回到前台时刷新消息中心：推送多在后台到达，回来要能立刻看到。
    if (state == AppLifecycleState.resumed && widget.session.isLoggedIn) {
      widget.session.requestMessagesRefresh();
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
          routerConfig: _router,
        ),
      ),
    );
  }
}
