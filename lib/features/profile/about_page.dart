import 'package:flutter/material.dart';

import '../../data/app_update.dart';
import '../../data/wo_session.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_card.dart';

/// 关于「窝」：展示版本信息 + 检查更新（下载并安装最新 APK）。
///
/// 更新状态由 [WoSession.appUpdate]（与 App 同生命周期）承载，本页只是它的视图。
/// 因此下载过程中离开本页不会中断下载，重新进来能看到当前进度。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) WoScope.of(context).appUpdate.loadCurrentInfo();
    });
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final controller = WoScope.of(context).appUpdate;

    return Scaffold(
      appBar: AppBar(title: const Text('关于「窝」')),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final versionLine = controller.currentVersionName.isEmpty
                ? '版本 …'
                : '版本 ${controller.currentVersionName} (${controller.currentBuild})';
            return ListView(
              padding: const EdgeInsets.all(WoTokens.space5),
              children: [
                const SizedBox(height: WoTokens.space4),
                Center(
                  child: Column(
                    children: [
                      Container(
                        width: 84,
                        height: 84,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: wo.accentSoft,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text('🏠', style: TextStyle(fontSize: 44)),
                      ),
                      const SizedBox(height: WoTokens.space3),
                      Text('窝', style: t.titleLarge),
                      const SizedBox(height: WoTokens.space1),
                      Text(
                        versionLine,
                        style: t.bodyMedium?.copyWith(color: wo.fgMid),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: WoTokens.space6),
                WoCard(
                  padding: const EdgeInsets.all(WoTokens.space5),
                  child: _buildUpdateSection(context, controller),
                ),
                const SizedBox(height: WoTokens.space5),
                Center(
                  child: Text(
                    '插件化家庭事务 App',
                    style: t.bodySmall?.copyWith(color: wo.fgMid),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildUpdateSection(BuildContext context, AppUpdateController c) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;

    switch (c.phase) {
      case AppUpdatePhase.checking:
        return Row(
          children: const [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: WoTokens.space3),
            Text('正在检查更新…'),
          ],
        );

      case AppUpdatePhase.downloading:
        final pct = c.progress;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pct == null
                  ? '正在下载…'
                  : '正在下载… ${(pct * 100).toStringAsFixed(0)}%',
              style: t.bodyMedium,
            ),
            const SizedBox(height: WoTokens.space3),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: pct),
            ),
            const SizedBox(height: WoTokens.space2),
            Text(
              '下载在后台继续，可离开本页面。',
              style: t.bodySmall?.copyWith(color: wo.fgMid),
            ),
          ],
        );

      case AppUpdatePhase.available:
        final release = c.release!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.system_update, color: wo.accent),
                const SizedBox(width: WoTokens.space2),
                Expanded(
                  child: Text(
                    '发现新版本 ${release.versionName}'
                    '${release.size > 0 ? ' · ${_formatSize(release.size)}' : ''}',
                    style: t.titleMedium,
                  ),
                ),
              ],
            ),
            if (release.notes.isNotEmpty) ...[
              const SizedBox(height: WoTokens.space3),
              Text(release.notes, style: t.bodyMedium?.copyWith(color: wo.fgMid)),
            ],
            if (c.message != null) ...[
              const SizedBox(height: WoTokens.space2),
              Text(
                c.message!,
                style: t.bodySmall?.copyWith(color: Colors.redAccent),
              ),
            ],
            const SizedBox(height: WoTokens.space4),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: c.downloadAndInstall,
                icon: const Icon(Icons.download),
                label: const Text('立即更新'),
              ),
            ),
          ],
        );

      case AppUpdatePhase.upToDate:
        return Row(
          children: [
            Icon(Icons.check_circle_outline, color: wo.accent),
            const SizedBox(width: WoTokens.space2),
            const Expanded(child: Text('已是最新版本')),
            TextButton(onPressed: c.check, child: const Text('重新检查')),
          ],
        );

      case AppUpdatePhase.idle:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (c.message != null) ...[
              Text(
                c.message!,
                style: t.bodySmall?.copyWith(color: Colors.redAccent),
              ),
              const SizedBox(height: WoTokens.space3),
            ],
            FilledButton.tonalIcon(
              onPressed: c.check,
              icon: const Icon(Icons.refresh),
              label: const Text('检查更新'),
            ),
          ],
        );
    }
  }
}
