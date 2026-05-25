import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../navigation/wo_routes.dart';
import '../theme/wo_tokens.dart';

/// 主壳子：底 Tab + 当前 Tab 的内容区。
///
/// 用 [StatefulNavigationShell] 承载三个 Tab。点底 Tab 一律回到该 Tab 的根页，
/// 不会停留在之前压入的二级页（如插件详情页）。
class WoShell extends StatelessWidget {
  const WoShell({
    super.key,
    required this.shell,
    required this.homeBranchKey,
  });

  final StatefulNavigationShell shell;

  /// 首页 Tab 的 navigator key，用于切 Tab 时清掉命令式压入的插件详情页。
  final GlobalKey<NavigatorState> homeBranchKey;

  static const _tabs = <_TabItem>[
    _TabItem(label: '首页', emoji: '🏡', route: WoRoutes.home),
    _TabItem(label: '消息', emoji: '💬', route: WoRoutes.messages),
    _TabItem(label: '我的', emoji: '👤', route: WoRoutes.me),
  ];

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Scaffold(
      body: shell,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: wo.bg,
          border: Border(top: BorderSide(color: wo.hairline)),
        ),
        child: SafeArea(
          top: false,
          child: NavigationBar(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: (i) {
              // 点 Tab 一律回到该 Tab 的根页：声明式页面用 initialLocation 重置，
              // 首页里命令式压入的插件详情页再用 popUntil 清掉。
              shell.goBranch(i, initialLocation: true);
              homeBranchKey.currentState?.popUntil((r) => r.isFirst);
            },
            destinations: [
              for (final tab in _tabs)
                NavigationDestination(
                  icon: Text(tab.emoji, style: const TextStyle(fontSize: 22)),
                  label: tab.label,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabItem {
  const _TabItem({
    required this.label,
    required this.emoji,
    required this.route,
  });
  final String label;
  final String emoji;
  final String route;
}
