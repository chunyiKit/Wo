import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../data/wo_session.dart';
import '../../widgets/wo_cinema.dart';

/// 首页与预览使用相同的裁切和遮罩；失败时回退默认背景。
class FamilyHomeBackground extends StatelessWidget {
  const FamilyHomeBackground({super.key, this.url, this.preview});

  final String? url;
  final Uint8List? preview;

  @override
  Widget build(BuildContext context) {
    Widget fallback() => Image.asset(
          WoCinemaBackdrop.asset,
          fit: BoxFit.cover,
          alignment: const Alignment(.35, -.25),
          errorBuilder: (_, __, ___) =>
              const ColoredBox(color: Color(0xFF533021)),
        );
    if (preview == null && url == null) return fallback();
    final api = WoScope.api(context);
    Widget shade(Widget picture) => Stack(
          fit: StackFit.expand,
          children: [picture, const ColoredBox(color: Color(0x99000000))],
        );
    if (preview != null) {
      return shade(
        Image.memory(preview!, fit: BoxFit.cover, gaplessPlayback: true),
      );
    }
    return CachedNetworkImage(
      key: ValueKey(url),
      imageUrl: '${api.baseUrl}$url',
      httpHeaders: api.imageHeaders,
      imageBuilder: (_, provider) =>
          shade(Image(image: provider, fit: BoxFit.cover)),
      placeholder: (_, __) => fallback(),
      errorWidget: (_, __, ___) => fallback(),
    );
  }
}
