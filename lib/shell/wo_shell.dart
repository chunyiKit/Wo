import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/wo_session.dart';
import '../navigation/wo_routes.dart';
import '../theme/wo_tokens.dart';
import 'package:flutter/services.dart';

/// 主壳子：底 Tab + 当前 Tab 的内容区。
///
/// 用 [StatefulNavigationShell] 承载三个 Tab。点底 Tab 一律回到该 Tab 的根页，
/// 不会停留在之前压入的二级页（如插件详情页）。
class WoShell extends StatelessWidget {
  const WoShell({super.key, required this.shell, required this.homeBranchKey});

  final StatefulNavigationShell shell;

  /// 首页 Tab 的 navigator key，用于切 Tab 时清掉命令式压入的插件详情页。
  final GlobalKey<NavigatorState> homeBranchKey;

  static const _tabs = <_TabItem>[
    _TabItem(
      label: '首页',
      icon: Icons.home_outlined,
      selectedIcon: Icons.home_rounded,
      route: WoRoutes.home,
    ),
    _TabItem(
      label: '消息',
      icon: Icons.chat_bubble_outline_rounded,
      selectedIcon: Icons.chat_bubble_rounded,
      route: WoRoutes.messages,
    ),
    _TabItem(
      label: '我的',
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
      route: WoRoutes.me,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    // 订阅会话：未读数变化时（拉取 bootstrap / 收到推送）重建底 Tab 角标。
    final session = WoScope.of(context);
    final unread = session.unreadCount;
    return Scaffold(
      body: shell,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Container(
            decoration: BoxDecoration(
              color: wo.bgElev,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: wo.hairline, width: .8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .12),
                  blurRadius: 24,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = (constraints.maxWidth - 12) / 3;
                return Stack(
                  children: [
                    AnimatedPositioned(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 380),
                      curve: Curves.easeOutCubic,
                      left: 6 + width * shell.currentIndex,
                      top: 6,
                      bottom: 6,
                      width: width,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: wo.accentSoft,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: wo.accent.withValues(alpha: .25),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: Row(
                        children: [
                          for (var i = 0; i < _tabs.length; i++)
                            Expanded(
                              child: Semantics(
                                selected: shell.currentIndex == i,
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(18),
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      shell.goBranch(i, initialLocation: true);
                                      homeBranchKey.currentState
                                          ?.popUntil((r) => r.isFirst);
                                      if (_tabs[i].route == WoRoutes.messages) {
                                        session.requestMessagesRefresh();
                                      }
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 11,
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Badge(
                                            isLabelVisible:
                                                i == 1 && unread > 0,
                                            label: Text(
                                              unread > 99 ? '99+' : '$unread',
                                            ),
                                            child: Icon(
                                              shell.currentIndex == i
                                                  ? _tabs[i].selectedIcon
                                                  : _tabs[i].icon,
                                              size: 22,
                                              color: shell.currentIndex == i
                                                  ? wo.accent
                                                  : wo.fgMid,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            _tabs[i].label,
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: shell.currentIndex == i
                                                  ? wo.accent
                                                  : wo.fgMid,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _TabItem {
  const _TabItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.route,
  });
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String route;
}
