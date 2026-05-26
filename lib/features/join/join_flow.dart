import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';

/// 从扫码内容里提取邀请码。兼容三种形式：
/// - 深链 `wo://join?c=SLUG`（二维码 payload）
/// - 链接 `https://.../join/SLUG`
/// - 直接的邀请码（交给后端 normalize）
String? extractInviteCode(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final uri = Uri.tryParse(s);
  if (uri != null) {
    final c = uri.queryParameters['c'];
    if (c != null && c.isNotEmpty) return c;
    final segs = uri.pathSegments;
    final i = segs.indexOf('join');
    if (i >= 0 && i + 1 < segs.length && segs[i + 1].isNotEmpty) {
      return segs[i + 1];
    }
  }
  return s;
}

/// 加入家庭统一流程：预览 → 确认 → 接受 → 切换 → 回首页。
/// 成功返回 true（并已跳首页）；用户取消或失败返回 false（失败会弹提示）。
Future<bool> joinFamilyWithCode(BuildContext context, String code) async {
  final session = WoScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final router = GoRouter.of(context);
  try {
    final preview = await session.api.previewInvitation(code);
    if (!context.mounted) return false;
    final confirmed = await _confirm(context, preview);
    if (confirmed != true) return false;
    final family = await session.api.acceptInvitation(code);
    await session.switchFamily(family.id);
    messenger.showSnackBar(SnackBar(content: Text('已加入「${family.name}」')));
    router.go(WoRoutes.home);
    return true;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(_errorText(e))));
    return false;
  }
}

String _errorText(Object e) => switch (e) {
      ApiException a => a.message,
      NetworkException a => a.message,
      _ => '加入失败',
    };

Future<bool?> _confirm(BuildContext context, InvitationPreview p) {
  final t = Theme.of(context).textTheme;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(p.familyEmoji, style: const TextStyle(fontSize: 48)),
          const SizedBox(height: WoTokens.space3),
          Text(
            '加入「${p.familyName}」？',
            style: t.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: WoTokens.space2),
          Text(
            [
              '${p.memberCount} 位成员',
              if (p.inviterName != null) '${p.inviterName} 邀请你',
            ].join(' · '),
            style: t.bodySmall?.copyWith(color: ctx.wo.fgMid),
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('加入'),
        ),
      ],
    ),
  );
}
