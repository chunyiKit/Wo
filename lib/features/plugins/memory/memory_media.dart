import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';

/// 单个媒体方块：照片走网络图，视频走暖色占位 + 播放角标 + 时长。
///
/// 只有传了 [onTap] 时才拦截点击；否则点击会冒泡给父级（例如列表卡片整体进详情）。
/// 视频的播放、照片的看大图，都由调用方（详情页 → 大图画廊）决定。
class MemoryMediaTile extends StatelessWidget {
  const MemoryMediaTile({
    super.key,
    required this.media,
    this.radius = 0,
    this.fit = BoxFit.cover,
    this.onTap,
  });

  final MemoryMedia media;
  final double radius;
  final BoxFit fit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final api = WoScope.api(context);
    final url = api.memoryMediaUrl(media);

    Widget content;
    if (media.isVideo) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: wo.memory),
          const Center(
            child: Icon(Icons.play_circle_fill, size: 40, color: Colors.white),
          ),
          if (media.durationLabel != null)
            Positioned(
              left: 6,
              bottom: 6,
              child: _Badge(text: media.durationLabel!),
            ),
        ],
      );
    } else {
      content = CachedNetworkImage(
        imageUrl: url,
        httpHeaders: api.imageHeaders,
        fit: fit,
        placeholder: (_, __) => ColoredBox(color: wo.memory),
        errorWidget: (_, __, ___) => ColoredBox(
          color: wo.memory,
          child: const Center(
            child: Icon(Icons.broken_image_outlined, color: Colors.white70),
          ),
        ),
      );
    }

    final clipped = radius > 0
        ? ClipRRect(borderRadius: BorderRadius.circular(radius), child: content)
        : content;

    if (onTap == null) return clipped;
    return GestureDetector(onTap: onTap, child: clipped);
  }
}

/// 照片/视频自适应网格，照搬设计：1 张大图、2 张并排、3 张「左大右二」、4+ 宫格。
class MemoryMediaGrid extends StatelessWidget {
  const MemoryMediaGrid({
    super.key,
    required this.media,
    this.radius = 12,
    this.maxTiles = 9,
    this.onTapMedia,
  });

  final List<MemoryMedia> media;
  final double radius;
  final int maxTiles;

  /// 传了就把每个格子的点击路由出去（带它在完整 media 列表里的下标），
  /// 详情页据此打开大图画廊。为空时格子不拦截点击（让父级处理）。
  final ValueChanged<int>? onTapMedia;

  @override
  Widget build(BuildContext context) {
    if (media.isEmpty) return const SizedBox.shrink();
    final shown = media.length > maxTiles ? media.sublist(0, maxTiles) : media;
    final overflow = media.length - shown.length;
    final n = shown.length;

    MemoryMediaTile tile(int i) => MemoryMediaTile(
          media: shown[i],
          onTap: onTapMedia == null ? null : () => onTapMedia!(i),
        );

    if (n == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: tile(0),
        ),
      );
    }

    if (n == 2) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: AspectRatio(
          aspectRatio: 2,
          child: Row(
            children: [
              Expanded(child: tile(0)),
              const SizedBox(width: 4),
              Expanded(child: tile(1)),
            ],
          ),
        ),
      );
    }

    if (n == 3) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: Row(
            children: [
              Expanded(flex: 14, child: tile(0)),
              const SizedBox(width: 4),
              Expanded(
                flex: 10,
                child: Column(
                  children: [
                    Expanded(child: tile(1)),
                    const SizedBox(height: 4),
                    Expanded(child: tile(2)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 4+：等宽宫格（4 张两列，更多三列），最后一格盖 +N。
    final cols = n == 4 ? 2 : 3;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: GridView.count(
        crossAxisCount: cols,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < n; i++)
            Stack(
              fit: StackFit.expand,
              children: [
                tile(i),
                if (overflow > 0 && i == n - 1)
                  ColoredBox(
                    color: Colors.black.withValues(alpha: 0.45),
                    child: Center(
                      child: Text(
                        '+$overflow',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// 把 event_date 转成时间线上的人类可读相对标签（今天 / 昨天 / N 天前 / 日期）。
String memoryDateLabel(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(date.year, date.month, date.day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  if (diff == 2) return '前天';
  if (diff > 2 && diff < 7) return '$diff 天前';
  if (diff >= 7 && diff < 14) return '上周';
  return '${date.month} 月 ${date.day} 日';
}

/// 月份分组标签：六月 · 2026。
String memoryMonthLabel(DateTime date) {
  const names = [
    '一月', '二月', '三月', '四月', '五月', '六月',
    '七月', '八月', '九月', '十月', '十一月', '十二月',
  ];
  return '${names[date.month - 1]} · ${date.year}';
}
