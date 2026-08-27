import 'package:flutter/material.dart';

import '../data/app_update.dart';
import '../theme/wo_tokens.dart';

/// 启动检查发现新版本后展示的全局提示。
///
/// 返回 `true` 表示立即更新，`false` 表示本次启动暂不更新。
class AppUpdateDialog extends StatelessWidget {
  const AppUpdateDialog({super.key, required this.release});

  final AppRelease release;

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final size = _formatSize(release.size);

    return WoAlertDialog(
      icon: const Icon(Icons.system_update_alt, size: 32),
      title: Text('发现新版本 ${release.versionName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              size.isEmpty ? '现在可以更新「窝」' : '安装包大小 $size',
              style: t.bodyMedium,
            ),
            if (release.notes.trim().isNotEmpty) ...[
              const SizedBox(height: WoTokens.space4),
              Text('更新内容', style: t.titleSmall),
              const SizedBox(height: WoTokens.space2),
              Text(release.notes.trim(), style: t.bodyMedium),
            ],
            const SizedBox(height: WoTokens.space3),
            Text(
              '点击更新后将在后台下载，下载完成会自动打开安装页面。',
              style: t.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        WoTextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('稍后'),
        ),
        WoFilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('立即更新'),
        ),
      ],
    );
  }
}
