import 'package:flutter/material.dart';

/// 卡片装饰背景：统一靠右下，尺寸随卡片高度适配，不参与内容的语义朗读。
class WoCardEmoji extends StatelessWidget {
  const WoCardEmoji({
    super.key,
    required this.emoji,
    required this.compact,
  });

  final String emoji;
  final bool compact;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = (compact
                    ? constraints.maxHeight * .48
                    : constraints.biggest.shortestSide * .42)
                .clamp(0.0, compact ? 48.0 : 76.0);
            return Padding(
              padding: const EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.bottomRight,
                child: Opacity(
                  opacity: .18,
                  child: SizedBox.square(
                    dimension: size,
                    child: FittedBox(
                      child: Text(
                        emoji,
                        textScaler: TextScaler.noScaling,
                        style: const TextStyle(fontSize: 64, height: 1),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
}
