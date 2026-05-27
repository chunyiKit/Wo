import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import 'memory_video_page.dart';

/// 全屏大图画廊：左右滑动看上一张 / 下一张，照片可双指缩放。
///
/// 翻到视频页时显示一个大播放按钮，点一下进全屏播放页。
class MemoryGalleryPage extends StatefulWidget {
  const MemoryGalleryPage({
    super.key,
    required this.media,
    this.initialIndex = 0,
  });

  final List<MemoryMedia> media;
  final int initialIndex;

  @override
  State<MemoryGalleryPage> createState() => _MemoryGalleryPageState();
}

class _MemoryGalleryPageState extends State<MemoryGalleryPage> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.media.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final api = WoScope.api(context);
    final total = widget.media.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          '${_index + 1} / $total',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: PageView.builder(
        controller: _controller,
        itemCount: total,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) {
          final m = widget.media[i];
          final url = api.memoryMediaUrl(m);
          if (m.isVideo) {
            return _VideoPage(url: url, durationLabel: m.durationLabel);
          }
          return InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: Center(
              child: CachedNetworkImage(
                imageUrl: url,
                httpHeaders: api.imageHeaders,
                fit: BoxFit.contain,
                placeholder: (_, __) => const Center(
                  child: CircularProgressIndicator(color: Colors.white24),
                ),
                errorWidget: (_, __, ___) => const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white38,
                    size: 48,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _VideoPage extends StatelessWidget {
  const _VideoPage({required this.url, this.durationLabel});

  final String url;
  final String? durationLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => MemoryVideoPage(url: url)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_circle_fill, size: 80, color: Colors.white),
            const SizedBox(height: 12),
            Text(
              durationLabel != null ? '点击播放 · $durationLabel' : '点击播放',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
