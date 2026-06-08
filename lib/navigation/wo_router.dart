import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/family/family_invite_page.dart';
import '../features/family/family_manage_page.dart';
import '../features/home/home_page.dart';
import '../features/join/create_family_page.dart';
import '../features/join/join_by_code_page.dart';
import '../features/auth/login_page.dart';
import '../features/join/join_landing_page.dart';
import '../features/join/scan_page.dart';
import '../features/marketplace/marketplace_page.dart';
import '../features/marketplace/plugin_detail_page.dart';
import '../features/messages/messages_page.dart';
import '../features/onboarding/onboarding_page.dart';
import '../features/profile/about_page.dart';
import '../features/profile/ai_integration_page.dart';
import '../features/profile/appearance_page.dart';
import '../features/profile/cache_cleanup_page.dart';
import '../features/profile/change_password_page.dart';
import '../features/profile/notification_prefs_page.dart';
import '../features/profile/profile_page.dart';
import '../features/profile/settings_page.dart';
import '../features/splash/splash_page.dart';
import '../shell/wo_shell.dart';
import 'wo_routes.dart';

/// 应用路由表。
///
/// 启动顺序：[WoRoutes.splash] → [WoRoutes.onboarding] → [WoRoutes.joinLanding]
///         → 主壳子（home / messages / me）。
/// 真实业务里 splash 决定下一跳由 SessionRepository / 本地存储决定，
/// 当前先静态跳到 onboarding。
final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'wo-root');

/// 首页 Tab 自己的 navigator key。插件详情页是用 [Navigator.push] 命令式压栈的，
/// goBranch 只会重置 go_router 的声明式页面，清不掉这种命令式路由，
/// 所以切 Tab 时需要拿这个 key 把首页栈 popUntil 回根页。
final _homeBranchKey = GlobalKey<NavigatorState>(debugLabel: 'wo-home-branch');

GoRouter buildRouter() {
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: WoRoutes.splash,
    routes: [
      GoRoute(
        path: WoRoutes.splash,
        builder: (_, __) => const SplashPage(),
      ),
      GoRoute(
        path: WoRoutes.onboarding,
        builder: (_, __) => const OnboardingPage(),
      ),
      GoRoute(
        path: WoRoutes.login,
        builder: (_, __) => const LoginPage(),
      ),

      // 加入 / 创建家庭流（独立栈，未登陆时进入）
      GoRoute(
        path: WoRoutes.joinLanding,
        builder: (_, __) => const JoinLandingPage(),
        routes: [
          GoRoute(
            path: 'code',
            builder: (_, __) => const JoinByCodePage(),
          ),
          GoRoute(
            path: 'scan',
            builder: (_, __) => const ScanPage(),
          ),
          GoRoute(
            path: 'create',
            builder: (_, __) => const CreateFamilyPage(),
          ),
        ],
      ),

      // 主壳子：每个 Tab 一个独立 navigator，保持各自栈
      StatefulShellRoute.indexedStack(
        builder: (_, __, shell) =>
            WoShell(shell: shell, homeBranchKey: _homeBranchKey),
        branches: [
          // ── 首页 Tab
          StatefulShellBranch(
            navigatorKey: _homeBranchKey,
            routes: [
              GoRoute(
                path: WoRoutes.home,
                builder: (_, __) => const HomePage(),
                routes: [
                  GoRoute(
                    path: 'marketplace',
                    builder: (_, __) => const MarketplacePage(),
                    routes: [
                      GoRoute(
                        path: 'plugin/:id',
                        builder: (_, state) => PluginDetailPage(
                          pluginId: state.pathParameters['id'] ?? '',
                        ),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'family',
                    builder: (_, __) => const FamilyManagePage(),
                    routes: [
                      GoRoute(
                        path: 'invite',
                        builder: (_, __) => const FamilyInvitePage(),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          // ── 消息 Tab
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: WoRoutes.messages,
                builder: (_, __) => const MessagesPage(),
              ),
            ],
          ),
          // ── 我的 Tab
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: WoRoutes.me,
                builder: (_, __) => const ProfilePage(),
                routes: [
                  GoRoute(
                    path: 'settings',
                    builder: (_, __) => const SettingsPage(),
                    routes: [
                      GoRoute(
                        path: 'appearance',
                        builder: (_, __) => const AppearancePage(),
                      ),
                      GoRoute(
                        path: 'notifications',
                        builder: (_, __) => const NotificationPrefsPage(),
                      ),
                      GoRoute(
                        path: 'ai-integration',
                        builder: (_, __) => const AiIntegrationPage(),
                      ),
                      GoRoute(
                        path: 'password',
                        builder: (_, __) => const ChangePasswordPage(),
                      ),
                      GoRoute(
                        path: 'cache',
                        builder: (_, __) => const CacheCleanupPage(),
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'about',
                    builder: (_, __) => const AboutPage(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
