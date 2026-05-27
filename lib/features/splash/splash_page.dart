import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';

/// 启动页：品牌底色 + Wo 圆环标记。浅/深两套配色随 app（系统）主题切换，
/// 与原生启动屏、应用图标视觉一致。拉取 bootstrap 后决定下一跳：
///   - 已有当前家庭 → 首页
///   - 还没有家庭   → 引导页（再去创建/加入）
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

/// 启动页标语池：每次启动随机挑一条展示。文案直接内置在 app 中。
const _taglines = <String>[
  '记录我们的生活',
  '把日子收进窝里',
  '一家人的小账本',
  '慢慢记，好好过',
  '有你在就是家',
  '我们的小窝',
  '回家就很好',
  '一起把家过好',
  '今天，我们吃了什么',
  '柴米油盐，都是浪漫',
  '今天也要好好吃饭',
  '平常日子，认真过',
  '在一起，刚刚好',
  '我们的每一天',
  '窝，是我们的',
];

class _SplashPageState extends State<SplashPage> {
  // 启动页最短停留时长：即使数据秒回也至少展示这么久，避免一闪而过。
  static const _minDisplay = Duration(milliseconds: 1500);
  // 跳转前的淡出时长。
  static const _fadeDuration = Duration(milliseconds: 400);

  // 本次启动随机选定的标语，只在进入时挑一次（rebuild/重试不会变）。
  final String _tagline = _taglines[Random().nextInt(_taglines.length)];

  Object? _error;
  double _opacity = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    final session = WoScope.of(context);
    setState(() {
      _error = null;
      _opacity = 1;
    });
    final startedAt = DateTime.now();

    // 恢复本地登录态。没登录 → 引导页（再去登录）。
    await session.restore();
    if (!mounted) return;

    String target;
    if (!session.isLoggedIn) {
      target = WoRoutes.onboarding;
    } else {
      // 已登录 → 拉首屏数据，按有无家庭决定落地页。
      await session.load();
      if (!mounted) return;
      if (session.error != null) {
        setState(() => _error = session.error);
        return;
      }
      target =
          session.currentFamily != null ? WoRoutes.home : WoRoutes.joinLanding;
    }

    // 补足最短停留：bootstrap 再快也要让品牌画面停够 1.5s。
    final remaining = _minDisplay - DateTime.now().difference(startedAt);
    if (remaining > Duration.zero) await Future.delayed(remaining);
    if (!mounted) return;

    // 淡出当前画面后再跳转。
    setState(() => _opacity = 0);
    await Future.delayed(_fadeDuration);
    if (!mounted) return;
    context.go(target);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? _SplashPalette.dark : _SplashPalette.light;
    final hasError = _error != null;

    return Scaffold(
      backgroundColor: palette.bg,
      body: AnimatedOpacity(
        opacity: _opacity,
        duration: _fadeDuration,
        curve: Curves.easeOut,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 132,
                height: 132,
                child: CustomPaint(painter: _WoMarkPainter(palette.mark)),
              ),
              const SizedBox(height: 28),
              Text(
                'Wo',
                style: TextStyle(
                  fontFamily: 'serif',
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w500,
                  fontSize: 56,
                  height: 1.0,
                  color: palette.title,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _tagline,
                style: TextStyle(
                  fontSize: 13,
                  letterSpacing: 3,
                  color: palette.subtitle,
                ),
              ),
              const SizedBox(height: 36),
              if (!hasError)
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: palette.mark,
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    _error is ApiException
                        ? (_error as ApiException).message
                        : _error is NetworkException
                            ? (_error as NetworkException).message
                            : '启动失败',
                    style: TextStyle(fontSize: 13, color: palette.subtitle),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(onPressed: _boot, child: const Text('重试')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 启动页配色：与原生 res/values(-night) 中的 wo_splash_bg、品牌标记色一致。
class _SplashPalette {
  const _SplashPalette({
    required this.bg,
    required this.mark,
    required this.title,
    required this.subtitle,
  });

  final Color bg;
  final Color mark;
  final Color title;
  final Color subtitle;

  static const light = _SplashPalette(
    bg: Color(0xFFF0E4D0),
    mark: Color(0xFFA8462E),
    title: Color(0xFF2A2118),
    subtitle: Color(0x8C2A2118), // rgba(42,33,24,.55)
  );

  static const dark = _SplashPalette(
    bg: Color(0xFF1F2733),
    mark: Color(0xFFF0E4D0),
    title: Color(0xFFF0E4D0),
    subtitle: Color(0x8CF0E4D0), // rgba(240,228,208,.55)
  );
}

/// Wo 圆环标记：一圈描边圆 + 两个实心点（按 1024 设计稿比例缩放绘制）。
class _WoMarkPainter extends CustomPainter {
  const _WoMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 1024;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 40 * s
      ..color = color;
    final dot = Paint()
      ..style = PaintingStyle.fill
      ..color = color;

    canvas.drawCircle(Offset(512 * s, 512 * s), 320 * s, ring);
    canvas.drawCircle(Offset(440 * s, 520 * s), 46 * s, dot);
    canvas.drawCircle(Offset(600 * s, 500 * s), 46 * s, dot);
  }

  @override
  bool shouldRepaint(_WoMarkPainter oldDelegate) => oldDelegate.color != color;
}
