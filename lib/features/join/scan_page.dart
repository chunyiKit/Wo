import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../theme/wo_tokens.dart';
import 'join_flow.dart';

/// 扫码加入：相机识别邀请二维码（深链 / 链接 / 邀请码均可），
/// 识别成功后走统一的预览→确认→加入流程。
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController _controller = MobileScannerController();

  /// 防止同一帧多个条码或连续帧重复触发加入。
  bool _handling = false;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  /// 拿到一段扫描文本后：提取邀请码并尝试加入。失败/取消则恢复扫描。
  Future<void> _handlePayload(String? raw) async {
    if (_handling || raw == null) return;
    final code = extractInviteCode(raw);
    if (code == null) return;

    setState(() => _handling = true);
    await _controller.stop();
    if (!mounted) return;

    final ok = await joinFamilyWithCode(context, code);
    if (!ok && mounted) {
      // 用户取消或加入失败：恢复扫描。
      setState(() => _handling = false);
      await _controller.start();
    }
  }

  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final result = await _controller.analyzeImage(picked.path);
    final raw = result?.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (!mounted) return;
    if (raw == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('图片里没有识别到二维码')));
      return;
    }
    await _handlePayload(raw);
  }

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
          actions: [
            IconButton(
              tooltip: '闪光灯',
              icon: const Icon(Icons.flash_on, color: Colors.white),
              onPressed: () => _controller.toggleTorch(),
            ),
          ],
        ),
        extendBodyBehindAppBar: true,
        body: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              controller: _controller,
              onDetect: (capture) {
                final raw = capture.barcodes
                    .map((b) => b.rawValue)
                    .firstWhere(
                      (v) => v != null && v.isNotEmpty,
                      orElse: () => null,
                    );
                _handlePayload(raw);
              },
              errorBuilder: (context, error, child) =>
                  _CameraError(error: error),
            ),
            // 暗化背景 + 取景框 + 操作。
            SafeArea(
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
                        _action(context, '📷', '相册', onTap: _pickFromGallery),
                        _action(
                          context,
                          '⌨️',
                          '手动输入',
                          onTap: () => context.pop(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
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

/// 相机不可用（权限被拒、无相机等）时的占位，引导手动输入。
class _CameraError extends StatelessWidget {
  const _CameraError({required this.error});
  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final msg = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied => '相机权限未开启，请在系统设置里允许后重试',
      _ => '相机不可用，可改用手动输入邀请码',
    };
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(WoTokens.space6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography, color: Colors.white54, size: 48),
          const SizedBox(height: WoTokens.space4),
          Text(
            msg,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: WoTokens.space5),
          FilledButton(
            onPressed: () => context.pop(),
            child: const Text('手动输入'),
          ),
        ],
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
