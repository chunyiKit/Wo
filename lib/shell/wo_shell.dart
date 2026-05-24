import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../navigation/wo_routes.dart';
import '../theme/wo_tokens.dart';

/// 主壳子：底 Tab + 当前 Tab 的内容区。
///
/// 用 [StatefulNavigationShell] 让每个 Tab 各自保持栈和状态，
/// 切换 Tab 不丢页面。
class WoShell extends StatelessWidget {
  const WoShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

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
            onDestinationSelected: (i) => shell.goBranch(
              i,
              initialLocation: i == shell.currentIndex,
            ),
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
