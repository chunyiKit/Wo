import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 统一的内容网络图（带鉴权头）。两件核心优化，解决带图详情页加载掉帧：
///
/// 1. **按显示尺寸解码**：`memCacheWidth = 显示宽 × dpr`。不传 [decodeWidth] 时用
///    LayoutBuilder 量出可用宽度。避免把原图（动辄 2000+px）整张解进内存——那是详情页
///    加载卡顿、爆 ImageCache 的主因。
/// 2. **等转场跑完再解码**（[deferUntilRouteSettled]）：所在路由的进场动画（含首页/列表
///    卡片放大形变那 380ms）未结束前只显示占位底色，动画跑完才开始加载解码，避免解码/
///    纹理上传跟动画抢光栅线程导致掉帧。
///
/// 占位用 tint 底色（不闪白）+ 轻微淡入。固定尺寸的小图（缩略图）建议显式传
/// [decodeWidth] 省一层 LayoutBuilder；[deferUntilRouteSettled] 对小图意义不大，可不开。
class WoNetworkImage extends StatefulWidget {
  const WoNetworkImage({
    super.key,
    required this.url,
    required this.headers,
    required this.placeholderColor,
    this.fit = BoxFit.cover,
    this.decodeWidth,
    this.deferUntilRouteSettled = false,
  });

  final String url;
  final Map<String, String> headers;

  /// 占位 / 出错时的底色（各插件传自己的 tint，如 wo.plant / wo.memory）。
  final Color placeholderColor;

  final BoxFit fit;

  /// 显式解码宽度（逻辑像素）。不传则用 LayoutBuilder 量到的可用宽度 × dpr。
  final double? decodeWidth;

  /// 等所在路由进场动画结束后再加载解码（默认否）。详情页大图建议开。
  final bool deferUntilRouteSettled;

  @override
  State<WoNetworkImage> createState() => _WoNetworkImageState();
}

class _WoNetworkImageState extends State<WoNetworkImage> {
  bool _ready = false;
  Animation<double>? _routeAnim;
  Timer? _fallback;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    if (!widget.deferUntilRouteSettled) {
      _ready = true;
      return;
    }
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.isCompleted) {
      _ready = true;
      return;
    }
    _routeAnim = anim..addStatusListener(_onRouteStatus);
    // 兜底:个别情况状态回调可能不触发,最多等一小段就强制加载,避免一直停在占位。
    _fallback = Timer(const Duration(milliseconds: 500), () {
      if (mounted && !_ready) setState(() => _ready = true);
    });
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted && !_ready) {
      setState(() => _ready = true);
    }
  }

  @override
  void dispose() {
    _fallback?.cancel();
    _routeAnim?.removeStatusListener(_onRouteStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return ColoredBox(color: widget.placeholderColor);

    final dpr = MediaQuery.of(context).devicePixelRatio;
    final explicit = widget.decodeWidth;
    if (explicit != null) return _image((explicit * dpr).round());

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth.isFinite && c.maxWidth > 0
            ? (c.maxWidth * dpr).round()
            : null;
        return _image(w);
      },
    );
  }

  Widget _image(int? memWidth) => CachedNetworkImage(
        imageUrl: widget.url,
        httpHeaders: widget.headers,
        fit: widget.fit,
        memCacheWidth: memWidth,
        fadeInDuration: const Duration(milliseconds: 180),
        placeholderFadeInDuration: Duration.zero,
        placeholder: (_, __) => ColoredBox(color: widget.placeholderColor),
        errorWidget: (_, __, ___) => ColoredBox(
          color: widget.placeholderColor,
          child: const Center(
            child: Icon(
              Icons.broken_image_outlined,
              color: Colors.white70,
              size: 22,
            ),
          ),
        ),
      );
}
