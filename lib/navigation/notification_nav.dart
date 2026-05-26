import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/wo_session.dart';
import '../features/family/family_manage_page.dart';
import '../features/plugins/accounting/accounting_page.dart';
import '../features/plugins/anniversary/anniversary_list_page.dart';

/// 通知点击跳转：根据 [WoNotification.deeplink] 打开对应页面。支持
///   wo://family/{fid}/plugins/anniversary  → 纪念日列表
///   wo://family/{fid}/plugins/accounting   → 记账
///   wo://family/{fid}/members              → 家庭成员
///
/// 目标家庭与当前不同时先 [WoSession.switchFamily]（这些页面都按 currentFamilyId
/// 取数）。deeplink 为空或无法识别则不跳转，调用方此时仅标记已读即可。
Future<void> openNotificationTarget(BuildContext context, WoNotification n) async {
  final target = _resolve(n.deeplink);
  if (target == null) return;

  final session = WoScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);

  if (target.familyId != null && target.familyId != session.currentFamilyId) {
    try {
      await session.switchFamily(target.familyId!);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('无法打开：你可能已不在该家庭')),
      );
      return;
    }
  }
  if (!context.mounted) return;
  navigator.push(MaterialPageRoute<void>(builder: (_) => target.page));
}

class _Target {
  const _Target(this.familyId, this.page);
  final String? familyId;
  final Widget page;
}

_Target? _resolve(String? deeplink) {
  if (deeplink == null || deeplink.isEmpty) return null;
  final uri = Uri.tryParse(deeplink);
  if (uri == null || uri.scheme != 'wo' || uri.host != 'family') return null;

  final segs = uri.pathSegments;
  if (segs.isEmpty) return null;
  final fid = segs.first;
  final rest = segs.sublist(1);

  Widget? page;
  if (rest.length == 2 && rest[0] == 'plugins') {
    page = switch (rest[1]) {
      'anniversary' => const AnniversaryListPage(),
      'accounting' => const AccountingPage(),
      _ => null,
    };
  } else if (rest.length == 1 && rest[0] == 'members') {
    page = const FamilyManagePage();
  }
  return page == null ? null : _Target(fid, page);
}
