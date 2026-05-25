import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  runApp(WoApp(session: WoSession()));
}

class WoApp extends StatefulWidget {
  const WoApp({super.key, required this.session});

  final WoSession session;

  @override
  State<WoApp> createState() => _WoAppState();
}

class _WoAppState extends State<WoApp> {
  // 路由表只构建一次，避免热重载时丢失导航栈。
  final _router = buildRouter();

  @override
  void dispose() {
    widget.session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WoScope(
      session: widget.session,
      child: MaterialApp.router(
        title: '窝',
        debugShowCheckedModeBanner: false,
        theme: WoTheme.light(),
        darkTheme: WoTheme.dark(),
        themeMode: ThemeMode.system,
        routerConfig: _router,
      ),
    );
  }
}
