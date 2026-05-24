import 'package:flutter/material.dart';

import '../theme/wo_tokens.dart';
import 'wo_card.dart';

/// 占位页面：暖橙圆形 emoji + 标题 + 解释 + CTA。
/// 让骨架直接跑起来时观感不"工具感"，符合「窝」的设计调性。
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    super.key,
    required this.emoji,
    required this.title,
    required this.description,
    this.ctaLabel,
    this.onCta,
    this.secondary,
  });

  final String emoji;
  final String title;
  final String description;
  final String? ctaLabel;
  final VoidCallback? onCta;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final wo = context.wo;
    return Padding(
      padding: const EdgeInsets.all(WoTokens.space6),
      child: Center(
        child: WoCard(
          padding: const EdgeInsets.symmetric(
            horizontal: WoTokens.space6,
            vertical: WoTokens.space8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 92,
                height: 92,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: wo.accentSoft,
                  shape: BoxShape.circle,
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 42)),
              ),
              const SizedBox(height: WoTokens.space5),
              Text(title, style: t.headlineSmall, textAlign: TextAlign.center),
              const SizedBox(height: WoTokens.space2),
              Text(
                description,
                style: t.bodyMedium?.copyWith(color: wo.fgMid),
                textAlign: TextAlign.center,
              ),
              if (ctaLabel != null) ...[
                const SizedBox(height: WoTokens.space5),
                FilledButton(onPressed: onCta, child: Text(ctaLabel!)),
              ],
              if (secondary != null) ...[
                const SizedBox(height: WoTokens.space2),
                secondary!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
