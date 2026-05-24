import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';

/// 启动页：暖橙渐变 + LOGO。拉取 bootstrap 后决定下一跳：
///   - 已有当前家庭 → 首页
///   - 还没有家庭   → 引导页（再去创建/加入）
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    final session = WoScope.of(context);
    setState(() => _error = null);

    // 恢复本地登录态。没登录 → 引导页（再去登录）。
    await session.restore();
    if (!mounted) return;
    if (!session.isLoggedIn) {
      context.go(WoRoutes.onboarding);
      return;
    }

    // 已登录 → 拉首屏数据，按有无家庭决定落地页。
    await session.load();
    if (!mounted) return;
    if (session.error != null) {
      setState(() => _error = session.error);
      return;
    }
    context.go(
      session.currentFamily != null ? WoRoutes.home : WoRoutes.joinLanding,
    );
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final hasError = _error != null;
    return Scaffold(
      backgroundColor: wo.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: wo.accent,
                borderRadius: BorderRadius.circular(24),
                boxShadow: WoTokens.fabShadow,
              ),
              child: const Text('🏡', style: TextStyle(fontSize: 40)),
            ),
            const SizedBox(height: WoTokens.space5),
            Text(
              '窝',
              style: t.displayMedium?.copyWith(letterSpacing: 2),
            ),
            const SizedBox(height: WoTokens.space6),
            if (!hasError)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              )
            else ...[
              Text(
                _error is ApiException
                    ? (_error as ApiException).message
                    : _error is NetworkException
                        ? (_error as NetworkException).message
                        : '启动失败',
                style: t.bodySmall?.copyWith(color: wo.fgMid),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: WoTokens.space4),
              FilledButton.tonal(onPressed: _boot, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}
