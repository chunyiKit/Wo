import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/wo_session.dart';
import '../../local/local_runtime.dart';
import '../settings/local_backup_page.dart';
import 'local_sync_page.dart';
import 'local_services_page.dart';
import '../auth/recovery_page.dart';
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
            if (session.api.isLocal) const WoListTile(title: Text('本机身份与家庭'), subtitle: Text('业务资料保存在本机；旧云账号不参与启动')) ,
            if (session.api.isLocal) WoListTile(
              title: const Text('本地配对与同步'),
              subtitle: const Text('同一 Wi-Fi 的家庭手机与伴侣范围授权'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const LocalSyncPage(),
              )),
            ),
            if (session.api.isLocal && LocalRuntime.instance != null) WoListTile(
              title: const Text('电脑备份与恢复校验'),
              subtitle: const Text('配对电脑、原件完整性和受限加密归档'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openBackup(context),
            ),
            if (session.api.isLocal && LocalRuntime.instance != null) WoListTile(
              title: const Text('本机可选服务'),
              subtitle: const Text('天气、只读电影查询和旅行图片模型'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => LocalServicesPage(settings: LocalRuntime.instance!.services),
              )),
            ),
            if (!session.api.isLocal) const WoListTile(

              title: Text('账号与安全'),
              trailing: Icon(Icons.chevron_right),
            ),
            if (!session.api.isLocal) WoListTile(
              title: const Text('恢复码与会话撤销'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const RecoveryPage(enroll: true),
              ),),
            ),
            if (!session.api.isLocal) WoListTile(
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
              title: Text(session.api.isLocal ? 'AI 集成设置（旧入口）' : 'AI 集成设置'),
              subtitle: Text(session.api.isLocal ? '其它旧 AI 能力尚未迁移；旅行模型使用本机可选服务' : '配置各类型 AI 的模型与密钥'),
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

Future<void> _openBackup(BuildContext context) async {
  final runtime = LocalRuntime.instance;
  if (runtime == null) return;
  try {
    final controller = await runtime.backupController;
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LocalBackupPage(controller: controller),
    ));
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      WoSnackBar(content: const Text('本机备份模块尚未就绪，现有资料仍保留在本机')),
    );
  }
}
