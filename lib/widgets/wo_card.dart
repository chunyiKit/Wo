import 'package:flutter/material.dart';

import '../theme/wo_tokens.dart';

/// 圆角 22 + 暖色阴影的标准卡片。
class WoCard extends StatelessWidget {
  const WoCard({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(WoTokens.space4),
    this.onTap,
    this.onLongPress,
    this.radius = WoTokens.cardRadius,
    this.showShadow = true,
  });

  final Widget child;
  final Color? color;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double radius;
  final bool showShadow;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final shape = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? wo.bgElev,
        borderRadius: shape,
        boxShadow: showShadow ? WoTokens.cardShadow : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: shape,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
