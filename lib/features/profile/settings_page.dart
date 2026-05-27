import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = WoScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        top: false,
        child: ListView(
          children: [
            const ListTile(
              title: Text('账号与安全'),
              trailing: Icon(Icons.chevron_right),
            ),
            ListTile(
              title: const Text('通知偏好'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(WoRoutes.notificationPrefs),
            ),
            ValueListenableBuilder<ThemeMode>(
              valueListenable: session.themeMode,
              builder: (context, mode, _) => ListTile(
                title: const Text('外观'),
                subtitle: Text(_themeModeLabel(mode)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(WoRoutes.appearance),
              ),
            ),
            const ListTile(title: Text('语言'), trailing: Icon(Icons.chevron_right)),
            const ListTile(
              title: Text('清除缓存'),
              trailing: Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
    );
  }
}

String _themeModeLabel(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return '浅色';
    case ThemeMode.dark:
      return '深色';
    case ThemeMode.system:
      return '跟随系统';
  }
}
