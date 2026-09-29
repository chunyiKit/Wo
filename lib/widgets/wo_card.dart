import 'package:flutter/material.dart';

import '../theme/wo_tokens.dart';

/// 琥珀细边与柔和反光的影院面板。
class WoCard extends StatefulWidget {
  const WoCard({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(WoTokens.space4),
    this.onTap,
    this.onLongPress,
    this.radius = WoTokens.cardRadius,
    this.showShadow = true,
    this.background,
  });

  final Widget child;
  final Color? color;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double radius;
  final bool showShadow;

  /// 裁剪在圆角内的背景层，不参与布局、不拦截卡片手势。
  final Widget? background;

  @override
  State<WoCard> createState() => _WoCardState();
}

class _WoCardState extends State<WoCard> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final shape = BorderRadius.circular(widget.radius);
    return AnimatedScale(
      scale: _pressed ? .985 : 1,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 130),
      curve: Curves.easeOutCubic,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                wo.accent.withValues(alpha: 0.035),
                widget.color ?? wo.bgElev,
              ),
              widget.color ?? wo.bgElev,
            ],
          ),
          border: Border.all(color: wo.hairline, width: 0.7),
          borderRadius: shape,
          boxShadow: widget.showShadow ? WoTokens.cardShadow : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              if (widget.background != null)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: shape,
                    child: IgnorePointer(child: widget.background!),
                  ),
                ),
              InkWell(
                borderRadius: shape,
                onHighlightChanged:
                    widget.onTap == null && widget.onLongPress == null
                        ? null
                        : (value) => setState(() => _pressed = value),
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                child: Padding(padding: widget.padding, child: widget.child),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
