import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = WoScope.of(context);
    return WoScaffold(
      appBar: WoAppBar(title: const Text('设置')),
      body: SafeArea(
        top: false,
        child: ListView(
          children: [
            const WoListTile(
              title: Text('账号与安全'),
              trailing: Icon(Icons.chevron_right),
            ),
            WoListTile(
              title: const Text('修改密码'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(WoRoutes.changePassword),
            ),
            WoListTile(
              title: const Text('通知偏好'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(WoRoutes.notificationPrefs),
            ),
            WoListTile(
              title: const Text('AI 集成设置'),
              subtitle: const Text('配置各类型 AI 的模型与密钥'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(WoRoutes.aiIntegration),
            ),
            ValueListenableBuilder<ThemeMode>(
              valueListenable: session.themeMode,
              builder: (context, mode, _) => WoListTile(
                title: const Text('外观'),
                subtitle: Text(_themeModeLabel(mode)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(WoRoutes.appearance),
              ),
            ),
            const WoListTile(
              title: Text('语言'),
              trailing: Icon(Icons.chevron_right),
            ),
            WoListTile(
              title: const Text('清除缓存'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(WoRoutes.clearCache),
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
