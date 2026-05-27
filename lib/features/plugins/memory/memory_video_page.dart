import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../data/wo_session.dart';

/// 全屏播放一段回忆视频。点画面切换播放/暂停，底部一条进度。
class MemoryVideoPage extends StatefulWidget {
  const MemoryVideoPage({super.key, required this.url});

  /// 完整地址（含 host）。
  final String url;

  @override
  State<MemoryVideoPage> createState() => _MemoryVideoPageState();
}

class _MemoryVideoPageState extends State<MemoryVideoPage> {
  VideoPlayerController? _controller;
  bool _ready = false;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller == null) _init();
  }

  Future<void> _init() async {
    final headers = WoScope.api(context).imageHeaders;
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
      httpHeaders: headers,
    );
    _controller = controller;
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.play();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _toggle() {
    final c = _controller;
    if (c == null || !_ready) return;
    setState(() => c.value.isPlaying ? c.pause() : c.play());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      extendBodyBehindAppBar: true,
      body: Center(
        child: _error != null
            ? const Text('视频加载失败', style: TextStyle(color: Colors.white70))
            : (!_ready || c == null)
                ? const CircularProgressIndicator(color: Colors.white)
                : GestureDetector(
                    onTap: _toggle,
                    child: AspectRatio(
                      aspectRatio: c.value.aspectRatio == 0
                          ? 16 / 9
                          : c.value.aspectRatio,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          VideoPlayer(c),
                          VideoProgressIndicator(c, allowScrubbing: true),
                          if (!c.value.isPlaying)
                            const Icon(
                              Icons.play_circle_fill,
                              size: 72,
                              color: Colors.white70,
                            ),
                        ],
                      ),
                    ),
                  ),
      ),
    );
  }
}
