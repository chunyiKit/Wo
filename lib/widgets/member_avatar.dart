import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/wo_session.dart';
import '../theme/wo_tokens.dart';

/// 家庭成员头像：有上传的真实头像就显示照片，否则回退到 emoji 圆形底。
///
/// [url] 是后端给的相对地址（含 /api/v1，带 ?v= 缓存键），为空走 emoji。
/// 各插件展示「是谁」时统一用它（回忆作者、记账记录人等）。
class MemberAvatar extends StatelessWidget {
  const MemberAvatar({
    super.key,
    required this.url,
    required this.emoji,
    this.size = 20,
  });

  final String? url;
  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final emojiCircle = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: wo.bgTint, shape: BoxShape.circle),
      child: Text(emoji, style: TextStyle(fontSize: size * 0.62)),
    );
    if (url == null || url!.isEmpty) return emojiCircle;

    final api = WoScope.api(context);
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: '${api.baseUrl}${url!}',
        httpHeaders: api.imageHeaders,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => emojiCircle,
        errorWidget: (_, __, ___) => emojiCircle,
      ),
    );
  }
}
