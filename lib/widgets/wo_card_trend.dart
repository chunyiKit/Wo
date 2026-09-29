import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme/wo_tokens.dart';

/// 首页卡片的低对比度趋势背景，前景文案保持原有不透明度。
class WoCardTrend extends StatelessWidget {
  const WoCardTrend({super.key, required this.trend});

  final BackgroundTrend trend;

  @override
  Widget build(BuildContext context) {
    final points = trend.points;
    if (points.length < 2 || points.any((p) => !p.value.isFinite)) {
      return const SizedBox.shrink();
    }
    return Semantics(
      image: true,
      label:
          '${trend.label}，${points.map((p) => '${p.date}：${p.value.toStringAsFixed(2)}${trend.unit}').join('，')}',
      child: CustomPaint(
        painter: _TrendPainter(
          values: points.map((p) => p.value).toList(),
          color: context.wo.accent,
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 24 || size.height <= 24) return;
    final min = math.min(0.0, values.reduce(math.min));
    final max = math.max(0.0, values.reduce(math.max));
    final range = max - min;
    final bottom = size.height - 12;
    final chartHeight = (size.height - 24) * .72;
    final points = [
      for (var i = 0; i < values.length; i++)
        Offset(
          12 + (size.width - 24) * i / (values.length - 1),
          bottom - (range == 0 ? 0 : (values[i] - min) / range) * chartHeight,
        ),
    ];
    final line = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      line.lineTo(point.dx, point.dy);
    }
    final area = Path.from(line)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .09), color.withValues(alpha: .015)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color.withValues(alpha: .22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    final dot = Paint()..color = color.withValues(alpha: .28);
    for (final point in points) {
      canvas.drawCircle(point, 2.6, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      color != oldDelegate.color || !listEquals(values, oldDelegate.values);
}
