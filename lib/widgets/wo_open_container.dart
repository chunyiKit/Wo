import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

import '../theme/wo_tokens.dart';

/// 卡片 → 详情页的形变转场封装。
///
/// 点击时 [closedBuilder] 的卡片放大形变成 [openBuilder] 的详情页，返回时缩回卡片。
/// 统一了一套配置，首页插件卡、回忆时间线卡等复用，观感一致：
///
/// - `closedColor` 透明 + `closedElevation: 0`：让底下卡片自带的圆角与暖阴影透出来，
///   不被 OpenContainer 再叠一层背景 / 阴影；
/// - `tappable: false`：点击交给卡片自己的 InkWell（[closedBuilder] 拿到的 `open`），
///   保留水波纹手感；
/// - `onClosed`：详情页返回时回调，返回值透传（如回忆详情返回 `true` 表示有改动）。
class WoOpenContainer extends StatelessWidget {
  const WoOpenContainer({
    super.key,
    required this.closedBuilder,
    required this.openBuilder,
    this.onClosed,
    this.radius = WoTokens.cardRadius,
    this.transitionDuration = const Duration(milliseconds: 380),
  });

  /// 闭合态（卡片）。`open` 调用即触发形变展开，把它接到卡片的 onTap 上。
  final Widget Function(BuildContext context, VoidCallback open) closedBuilder;

  /// 展开态（详情页）。仅在展开时构建。
  final WidgetBuilder openBuilder;

  /// 详情页返回后的回调，参数为详情页 pop 的返回值（可为 null）。
  final void Function(Object? returnValue)? onClosed;

  /// 形变时的圆角，与卡片圆角对齐，过渡中不露直角。
  final double radius;

  final Duration transitionDuration;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return OpenContainer<Object?>(
      tappable: false,
      closedElevation: 0,
      closedColor: Colors.transparent,
      openColor: wo.bg,
      middleColor: wo.bg,
      closedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      transitionType: ContainerTransitionType.fadeThrough,
      transitionDuration: transitionDuration,
      closedBuilder: (context, open) => closedBuilder(context, open),
      openBuilder: (context, _) => openBuilder(context),
      onClosed: onClosed,
    );
  }
}
