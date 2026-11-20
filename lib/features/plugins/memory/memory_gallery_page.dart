import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../local/local_runtime.dart';
import '../../../theme/wo_tokens.dart';
import 'memory_save.dart';
import 'local_memory_media.dart';
import 'memory_video_page.dart';

/// 全屏大图画廊：左右滑动看上一张 / 下一张，照片可双指缩放、长按可保存到相册。
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
  LocalRuntime? _runtime;
  bool _localInitialized = false, _checkingLocal = false, _localAllowed = false;
  int _permissionRequest = 0;
  String? _validatedFamily;

  @override
  void initState() {
    super.initState();
    _index = widget.media.isEmpty ? 0 : widget.initialIndex.clamp(0, widget.media.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (WoScope.api(context).isLocal && (!_localInitialized ||
        _validatedFamily != WoScope.of(context).currentFamilyId)) {
      if (!_localInitialized) {
        _runtime = LocalRuntime.instance;
        _runtime?.changes.addListener(_localChanged);
      }
      _localInitialized = true; _checkingLocal = true;
      _validatedFamily = WoScope.of(context).currentFamilyId;
      _validateLocal();
    }
  }

  void _localChanged() {
    if (!mounted) return;
    setState(() => _checkingLocal = true);
    _validateLocal();
  }

  Future<void> _validateLocal() async {
    final request = ++_permissionRequest;
    final family = WoScope.of(context).currentFamilyId;
    var allowed = family != null && widget.media.isNotEmpty;
    if (allowed) {
      for (final media in widget.media) {
        if (!await localMemoryMediaVisible(media, family!)) { allowed = false; break; }
      }
    }
    if (mounted && request == _permissionRequest &&
        family == WoScope.of(context).currentFamilyId) {
      setState(() { _checkingLocal = false; _localAllowed = allowed; });
    }
  }

  @override
  void dispose() {
    _runtime?.changes.removeListener(_localChanged);
    _controller.dispose();
    super.dispose();
  }

  /// 长按图片 → 微信式的底部「保存到相册」操作面板。
  ///
  /// 走 [showWoModalBottomSheet] 是因为照片这一页是黑底全屏,Material dialog 在
  /// 黑色背景上显得突兀;底部面板从下方升起,跟系统分享面板一致。
  Future<void> _onLongPressPhoto(MemoryMedia media, String url) async {
    final api = WoScope.api(context);
    if (api.isLocal) { await openLocalMemoryOriginal(context, media); return; }
    final action = await showWoModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            WoListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('保存到相册'),
              onTap: () => Navigator.of(ctx).pop('save'),
            ),
            WoListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      ),
    );
    if (action != 'save' || !mounted) return;

    // 用 messenger 句柄而不是再次 of(context),避免后续 await 后 context 可能被
    // 卸载导致取不到 ScaffoldMessenger。
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      WoSnackBar(content: Text('正在保存…'), duration: Duration(seconds: 30)),
    );
    final err = await saveMemoryImageToGallery(
      media: media,
      url: url,
      headers: api.imageHeaders,
    );
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      WoSnackBar(
        content: Text(err ?? '已保存到相册'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if(widget.media.isEmpty)return Scaffold(backgroundColor:Colors.black,appBar:AppBar(title:const Text('回忆媒体')),body:const Center(child:Text('没有可查看的媒体')));
    final api = WoScope.api(context);
    if (api.isLocal && (_checkingLocal || !_localAllowed)) {
      return WoScaffold(backgroundColor: Colors.black,
        appBar: WoAppBar(title: const Text('回忆'), foregroundColor: Colors.white,
          backgroundColor: Colors.transparent),
        body: Center(child: _checkingLocal ? const WoProgressIndicator(color: Colors.white24)
          : const Text('此媒体已删除或当前身份无权访问', style: TextStyle(color: Colors.white70))));
    }
    final total = widget.media.length;
    return WoScaffold(
      backgroundColor: Colors.black,
      appBar: WoAppBar(
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
          if (api.isLocal) return _LocalMediaPage(media: m);
          final url = api.memoryMediaUrl(m);
          if (m.isVideo) {
            return _VideoPage(url: url, durationLabel: m.durationLabel);
          }
          return GestureDetector(
            // 长按落在 InteractiveViewer 外层,避免缩放手势把长按吞掉。
            onLongPress: () => _onLongPressPhoto(m, url),
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(
                child: CachedNetworkImage(
                  imageUrl: url,
                  httpHeaders: api.imageHeaders,
                  fit: BoxFit.contain,
                  // 全屏图按屏幕物理分辨率解码即可,无需把 2400px 原图整张解进内存
                  // (那是撑爆 ImageCache、返回后缩略图全部重载的元凶之一)。
                  memCacheWidth: (MediaQuery.of(context).size.width *
                          MediaQuery.of(context).devicePixelRatio)
                      .round(),
                  placeholder: (_, __) => const Center(
                    child: WoProgressIndicator(color: Colors.white24),
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

/// 另一台手机只有缩略图；原件通过当前设备已有的授权引用交给系统预览。
class _LocalMediaPage extends StatelessWidget {
  const _LocalMediaPage({required this.media});
  final MemoryMedia media;
  @override
  Widget build(BuildContext context) => SafeArea(child: Column(children: [
    Expanded(child: InteractiveViewer(minScale: 1, maxScale: 4,
      child: Center(child: LocalMemoryThumbnail(media: media, fit: BoxFit.contain)))),
    const SizedBox(height: 12),
    Text(media.isVideo ? '视频缩略图 · 原视频仅在原设备或电脑备份中' : '照片缩略图 · 原照片仅在原设备或电脑备份中',
      textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 13)),
    const SizedBox(height: 8),
    WoTextButton(onPressed: () => openLocalMemoryOriginal(context, media),
      child: Text(media.isVideo ? '打开本机原视频' : '打开本机原照片', style: const TextStyle(color: Colors.white))),
    const SizedBox(height: 16),
  ]));
}
