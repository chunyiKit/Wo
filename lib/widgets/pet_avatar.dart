import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 宠物照片头像。宠物不是用户，使用独立照片端点；缺图或加载失败回退 emoji。
class PetAvatar extends StatelessWidget {
  const PetAvatar({
    super.key,
    required this.emoji,
    required this.size,
    required this.placeholderColor,
    this.bytes,
    this.url,
    this.headers = const {},
  });

  final String emoji;
  final double size;
  final Color placeholderColor;
  final Uint8List? bytes;
  final String? url;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: placeholderColor,
      child: Text(emoji, style: TextStyle(fontSize: size * .46)),
    );
    if (bytes != null) {
      return ClipOval(
        child: Image.memory(
          bytes!,
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    }
    if (url == null || url!.isEmpty) return ClipOval(child: fallback);
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url!,
        httpHeaders: headers,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => fallback,
        errorWidget: (_, __, ___) => fallback,
      ),
    );
  }
}
