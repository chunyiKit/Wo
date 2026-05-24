import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../theme/wo_tokens.dart';

/// 扫码加入：始终深色 + 暖橙四角识别框。
/// 真实业务里这里挂相机插件（mobile_scanner / camera）。
class ScanPage extends StatelessWidget {
  const ScanPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          title: const Text('扫码加入', style: TextStyle(color: Colors.white)),
          leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => context.pop(),
          ),
        ),
        extendBodyBehindAppBar: true,
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(),
              Center(
                child: CustomPaint(
                  size: const Size(240, 240),
                  painter: _ScanFramePainter(WoTokens.accent),
                ),
              ),
              const SizedBox(height: WoTokens.space5),
              const Text(
                '将二维码对准取景框',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.all(WoTokens.space6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _action(context, '📷', '相册'),
                    _action(context, '⌨️', '手动输入', onTap: () => context.pop()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(
    BuildContext context,
    String emoji,
    String label, {
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: WoTokens.space5,
          vertical: WoTokens.space3,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanFramePainter extends CustomPainter {
  _ScanFramePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const corner = 28.0;
    // 四角
    canvas.drawLine(const Offset(0, 0), const Offset(corner, 0), p);
    canvas.drawLine(const Offset(0, 0), const Offset(0, corner), p);
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width - corner, 0),
      p,
    );
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, corner), p);
    canvas.drawLine(
      Offset(0, size.height),
      Offset(corner, size.height),
      p,
    );
    canvas.drawLine(
      Offset(0, size.height),
      Offset(0, size.height - corner),
      p,
    );
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width - corner, size.height),
      p,
    );
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width, size.height - corner),
      p,
    );
  }

  @override
  bool shouldRepaint(_ScanFramePainter old) => old.color != color;
}
