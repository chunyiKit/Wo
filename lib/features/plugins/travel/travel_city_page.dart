import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/wo_network_image.dart';
import '../memory/memory_detail_page.dart';
import 'memory_link_sheet.dart';

/// 某座城市的旅行图集:封面网格 → 点开全屏查看(可缩放)、下载、删除。
/// 任意删除后 pop 返回 true,通知地图刷新。
class TravelCityPage extends StatefulWidget {
  const TravelCityPage(
      {super.key, required this.cityName, required this.trips,});

  final String cityName;
  final List<TravelTrip> trips;

  @override
  State<TravelCityPage> createState() => _TravelCityPageState();
}

class _TravelCityPageState extends State<TravelCityPage> {
  late final List<TravelTrip> _trips = List.of(widget.trips);
  bool _changed = false;

  WoSession get _session => WoScope.of(context);
  String _full(String url) => '${_session.api.baseUrl}$url';

  Future<void> _delete(TravelTrip trip) async {
    try {
      await _session.api.deleteTravelTrip(_session.currentFamilyId!, trip.id);
      if (!mounted) return;
      setState(() {
        _trips.removeWhere((t) => t.id == trip.id);
        _changed = true;
      });
      if (_trips.isEmpty) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(switch (e) {
              ApiException ex => ex.message,
              NetworkException ex => ex.message,
              _ => '删除失败',
            },),
          ),
        );
      }
    }
  }

  /// 置 / 清某段旅行关联的回忆;成功后就地替换列表项并标记 _changed(退出刷新地图)。
  /// 返回更新后的 trip(失败返回 null 并提示)。
  Future<TravelTrip?> _setMemory(TravelTrip trip, String? memoryId) async {
    try {
      final updated = await _session.api
          .setTravelTripMemory(_session.currentFamilyId!, trip.id, memoryId);
      if (!mounted) return updated;
      setState(() {
        final i = _trips.indexWhere((t) => t.id == updated.id);
        if (i >= 0) _trips[i] = updated;
        _changed = true;
      });
      return updated;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(switch (e) {
              ApiException ex => ex.message,
              NetworkException ex => ex.message,
              _ => '操作失败,请稍后再试',
            },),
          ),
        );
      }
      return null;
    }
  }

  Future<void> _openViewer(int index) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _Viewer(
          trips: _trips,
          initialIndex: index,
          fullUrl: _full,
          headers: _session.api.imageHeaders,
          onDelete: _delete,
          onSetMemory: _setMemory,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: wo.bg,
        appBar: AppBar(
          title: Text(widget.cityName),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 8),
                child: Text('${_trips.length} 段旅行',
                    style: TextStyle(color: wo.fgMid, fontSize: 13),),
              ),
            ),
          ),
        ),
        body: SafeArea(
          top: false,
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 0.8,
            ),
            itemCount: _trips.length,
            itemBuilder: (_, i) => _cover(wo, _trips[i], i),
          ),
        ),
      ),
    );
  }

  Widget _cover(WoColors wo, TravelTrip trip, int i) {
    return GestureDetector(
      onTap: () => _openViewer(i),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            WoNetworkImage(
              url: _full(trip.imageUrl),
              headers: _session.api.imageHeaders,
              placeholderColor: wo.travel,
              decodeWidth: 360,
            ),
            if (trip.isGenerating)
              Container(
                color: Colors.black.withValues(alpha: 0.35),
                alignment: Alignment.center,
                child: const _Badge(text: '生成中…', icon: Icons.auto_awesome),
              ),
            if (trip.isFailed)
              const Positioned(
                top: 8,
                left: 8,
                child: _Badge(text: '生成失败', icon: Icons.error_outline),
              ),
            if (trip.caption != null && trip.caption!.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 16, 10, 8),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black54],
                    ),
                  ),
                  child: Text(
                    trip.caption!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.icon});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 14),
          const SizedBox(width: 5),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }
}

/// 全屏查看:PageView 翻看 + InteractiveViewer 缩放 + 下载 / 删除。
class _Viewer extends StatefulWidget {
  const _Viewer({
    required this.trips,
    required this.initialIndex,
    required this.fullUrl,
    required this.headers,
    required this.onDelete,
    required this.onSetMemory,
  });

  final List<TravelTrip> trips;
  final int initialIndex;
  final String Function(String) fullUrl;
  final Map<String, String> headers;
  final Future<void> Function(TravelTrip) onDelete;

  /// 置 / 清关联回忆,返回更新后的 trip(失败 null)。由城市页落地调用 API。
  final Future<TravelTrip?> Function(TravelTrip trip, String? memoryId)
      onSetMemory;

  @override
  State<_Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<_Viewer> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  // 本地可变副本:关联回忆后就地替换当前项,无需重建整页。
  late final List<TravelTrip> _trips = List.of(widget.trips);

  WoSession get _session => WoScope.of(context);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    final trip = _trips[_index];
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在保存…')));
    final err =
        await _saveToGallery(widget.fullUrl(trip.imageUrl), widget.headers);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(err ?? '已保存到相册')));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这段旅行'),
        content: const Text('删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final trip = _trips[_index];
    await widget.onDelete(trip);
    if (mounted) Navigator.of(context).pop();
  }

  // ── 关联回忆 ──────────────────────────────────────────────

  Future<void> _applySetMemory(TravelTrip trip, String? memoryId) async {
    final updated = await widget.onSetMemory(trip, memoryId);
    if (updated != null && mounted) {
      setState(() {
        final i = _trips.indexWhere((t) => t.id == updated.id);
        if (i >= 0) _trips[i] = updated;
      });
    }
  }

  Future<void> _pickAndLink() async {
    final trip = _trips[_index];
    final seed = (trip.place != null && trip.place!.isNotEmpty)
        ? trip.place
        : trip.cityName;
    final mem = await showMemoryLinkSheet(context, seedQuery: seed);
    if (mem != null) await _applySetMemory(trip, mem.id);
  }

  Future<void> _unlink() => _applySetMemory(_trips[_index], null);

  /// 跳转到关联回忆详情。回忆已删除 / 不可见时给出提示。
  Future<void> _openMemory(LinkedMemory lm) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final full =
          await _session.api.memory(_session.currentFamilyId!, lm.id);
      if (!mounted) return;
      await navigator.push<void>(
        MaterialPageRoute(builder: (_) => MemoryDetailPage(memory: full)),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(switch (e) {
            ApiException _ => '这段回忆可能已被删除或不可见,可重新关联',
            NetworkException ex => ex.message,
            _ => '打开回忆失败',
          },),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _trips.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('${_index + 1} / $total',
            style: const TextStyle(fontSize: 15),),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_outlined),
            onPressed: _download,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: total,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(
                child: WoNetworkImage(
                  url: widget.fullUrl(_trips[i].imageUrl),
                  headers: widget.headers,
                  placeholderColor: const Color(0xFF222222),
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: _linkPanel(_trips[_index]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkPanel(TravelTrip trip) {
    final mem = trip.memory;
    final box = BoxDecoration(
      color: Colors.black.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
    );
    if (mem == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          onTap: _pickAndLink,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: box,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.link, color: Colors.white, size: 18),
                SizedBox(width: 6),
                Text('关联回忆',
                    style: TextStyle(color: Colors.white, fontSize: 14),),
              ],
            ),
          ),
        ),
      );
    }
    final cover = mem.coverUrl;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: box,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 46,
              height: 46,
              child: cover != null
                  ? WoNetworkImage(
                      url: '${_session.api.baseUrl}$cover',
                      headers: widget.headers,
                      placeholderColor: const Color(0xFF333333),
                      decodeWidth: 100,
                    )
                  : Container(
                      color: const Color(0xFF333333),
                      alignment: Alignment.center,
                      child: const Text('📸', style: TextStyle(fontSize: 20)),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: () => _openMemory(mem),
              behavior: HitTestBehavior.opaque,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.auto_stories_outlined,
                          color: Colors.white70, size: 13,),
                      SizedBox(width: 4),
                      Text('关联回忆',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 11),),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    mem.title.isEmpty ? '一段回忆' : mem.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,),
                  ),
                ],
              ),
            ),
          ),
          TextButton(
            onPressed: () => _openMemory(mem),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 36),
            ),
            child: const Text('查看'),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            onSelected: (v) {
              if (v == 'relink') _pickAndLink();
              if (v == 'unlink') _unlink();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'relink', child: Text('重新关联')),
              PopupMenuItem(value: 'unlink', child: Text('取消关联')),
            ],
          ),
        ],
      ),
    );
  }
}

/// 下载一张图到系统相册。返回错误提示;null 表示成功。
Future<String?> _saveToGallery(String url, Map<String, String> headers) async {
  try {
    final ok = await Gal.hasAccess(toAlbum: true) ||
        await Gal.requestAccess(toAlbum: true);
    if (!ok) return '需要相册权限才能保存';
  } on GalException catch (e) {
    return '获取相册权限失败：${e.type.message}';
  }

  File cached;
  try {
    cached = await DefaultCacheManager().getSingleFile(url, headers: headers);
  } catch (_) {
    return '下载失败';
  }

  // 按文件头判断真实类型(AI 图多为 PNG),给临时副本正确扩展名,gal 才能正确入库。
  String ext = 'jpg';
  try {
    final head = await cached.openRead(0, 8).first;
    if (head.length >= 4 &&
        head[0] == 0x89 &&
        head[1] == 0x50 &&
        head[2] == 0x4E &&
        head[3] == 0x47) {
      ext = 'png';
    }
  } catch (_) {}

  final tmpDir = await getTemporaryDirectory();
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final target = File('${tmpDir.path}/wo-travel-$stamp.$ext');
  try {
    await cached.copy(target.path);
    await Gal.putImage(target.path, album: '窝');
  } on GalException catch (e) {
    return '保存失败：${e.type.message}';
  } catch (_) {
    return '保存失败';
  } finally {
    try {
      if (await target.exists()) await target.delete();
    } catch (_) {}
  }
  return null;
}
