// 本地 Android 视觉验收入口。release 始终构建 lib/main.dart。
import 'package:flutter/material.dart';
import 'dart:developer';
import 'dart:convert';
import 'package:wo/data/models.dart';
import 'package:wo/features/plugins/plugin_pages.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/navigation/wo_router.dart';
import 'package:wo/theme/wo_theme.dart';
import '../test/support/cinema_fixtures.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = await cinemaSession();
  final navigatorKey = GlobalKey<NavigatorState>();
  final router = buildRouter(rootNavigatorKey: navigatorKey);
  registerExtension('ext.wo.preview', (method, parameters) async {
    while (navigatorKey.currentState?.canPop() ?? false) {
      navigatorKey.currentState!.pop();
    }
    final route = parameters['route'];
    final plugin = parameters['plugin'];
    if (route != null) router.go(route);
    if (plugin != null) {
      router.go('/home');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final page =
            pluginPageFor(InstalledPlugin.fromJson(cinemaInstalled(plugin)));
        if (page != null) {
          navigatorKey.currentState!
              .push(MaterialPageRoute(builder: (_) => page));
        }
      });
    }
    return ServiceExtensionResponse.result(jsonEncode({'ok': true}));
  });
  router.go('/home');
  runApp(
    WoScope(
      session: session,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: session.themeMode,
        builder: (context, mode, child) => MaterialApp.router(
          title: '窝 · 本地视觉验收',
          debugShowCheckedModeBanner: false,
          theme: WoTheme.light(),
          darkTheme: WoTheme.dark(),
          themeMode: mode,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          routerConfig: router,
        ),
      ),
    ),
  );
}
