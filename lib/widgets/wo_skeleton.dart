import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../theme/wo_tokens.dart';

/// 骨架屏微光容器：用主题色给一整块占位子树罩上 shimmer 扫光。
///
/// 用法：把若干 [WoSkeletonBox] 摆成目标布局的「灰影」，外面包一层 [WoShimmer]，
/// 整片就会有一道暖色微光匀速扫过。首屏加载用它替代转圈，质感更好，且不违反
/// 「列表刷新不闪」——首屏本就无数据，骨架是合理的占位。
class WoShimmer extends StatelessWidget {
  const WoShimmer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    // base 是占位块的底色，highlight 是扫过的高光；都用 fgDim 叠在 elev 底上，
    // 自动适配深 / 浅色，保持暖调。
    final base = Color.alphaBlend(wo.fgDim.withValues(alpha: 0.18), wo.bgElev);
    final highlight = Color.alphaBlend(wo.fgDim.withValues(alpha: 0.05), wo.bgElev);
    return Shimmer.fromColors(
      baseColor: base,
      highlightColor: highlight,
      period: const Duration(milliseconds: 1200),
      child: child,
    );
  }
}

/// 单个占位块。颜色会被 [WoShimmer] 的渐变覆盖（BlendMode.srcATop），
/// 这里只要保证不透明即可，所以固定填白。
class WoSkeletonBox extends StatelessWidget {
  const WoSkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.radius = 8,
    this.shape = BoxShape.rectangle,
  });

  final double? width;
  final double height;
  final double radius;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: shape,
        borderRadius:
            shape == BoxShape.circle ? null : BorderRadius.circular(radius),
      ),
    );
  }
}
