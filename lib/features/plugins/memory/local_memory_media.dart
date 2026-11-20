import 'dart:io';

import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../local/local_runtime.dart';
import '../../../theme/wo_tokens.dart';

/// 先核对当前回忆和媒体权限，文件 ID 本身不构成读取授权。
Future<bool> localMemoryMediaVisible(MemoryMedia media, String familyId) async {
  final runtime = LocalRuntime.instance;
  if (runtime == null) return false;
  final revision = runtime.changes.value;
  try {
    final result = await runtime.memories.request('GET', familyId,
      ['memory', 'memories', media.memoryId]);
    if (runtime.changes.value != revision || result?.data is! Map) return false;
    final memory = Memory.fromJson(Map<String, dynamic>.from(result!.data as Map));
    return memory.media.any((item) => item.id == media.id && item.kind == media.kind);
  } catch (_) { return false; }
}

Future<File?> _authorizedThumbnail(MemoryMedia media, String familyId) async {
  if (!await localMemoryMediaVisible(media, familyId)) return null;
  return LocalRuntime.instance?.media.thumbnailFile(media.id);
}

/// 用户显式点开时由原生按本机引用预览；不会读 raw 网络地址或把缩略图当原件保存。
Future<void> openLocalMemoryOriginal(BuildContext context, MemoryMedia media) async {
  final familyId = WoScope.of(context).currentFamilyId;
  final runtime = LocalRuntime.instance;
  var opened = false;
  if (familyId != null && runtime != null &&
      await localMemoryMediaVisible(media, familyId) && context.mounted &&
      WoScope.of(context).currentFamilyId == familyId) {
    try { opened = await runtime.media.openOriginal(media.id); } catch (_) {}
  }
  if (!context.mounted || opened) return;
  ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content: const Text(
    '本机原件不可读取：可能仅同步了缩略图，或需要原设备权限、下载原件后重试。')));
}

/// 本地照片和视频均渲染 JPEG 缩略图；同步或权限变化后重新核权，不复用旧像素。
class LocalMemoryThumbnail extends StatefulWidget {
  const LocalMemoryThumbnail({super.key, required this.media,
    this.fit = BoxFit.cover, this.placeholderColor = Colors.transparent});
  final MemoryMedia media;
  final BoxFit fit;
  final Color placeholderColor;
  @override
  State<LocalMemoryThumbnail> createState() => _LocalMemoryThumbnailState();
}

class _LocalMemoryThumbnailState extends State<LocalMemoryThumbnail> {
  Future<File?>? _future;
  String? _familyId;
  int? _revision;
  @override
  void didUpdateWidget(covariant LocalMemoryThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.id != widget.media.id ||
        oldWidget.media.memoryId != widget.media.memoryId) _future = null;
  }
  Widget _missing() => ColoredBox(color: widget.placeholderColor,
    child: const Center(child: Icon(Icons.image_not_supported_outlined)));
  @override
  Widget build(BuildContext context) {
    final runtime = LocalRuntime.instance;
    final familyId = WoScope.of(context).currentFamilyId;
    if (runtime == null || familyId == null) return _missing();
    return ValueListenableBuilder<int>(valueListenable: runtime.changes,
      builder: (context, revision, _) {
        if (_future == null || _familyId != familyId || _revision != revision) {
          _familyId = familyId; _revision = revision;
          _future = _authorizedThumbnail(widget.media, familyId);
        }
        return FutureBuilder<File?>(future: _future, builder: (context, snapshot) {
          // FutureBuilder 可暂存上一 future 的 data；重新核权期间必须隐藏它。
          if (snapshot.connectionState != ConnectionState.done ||
              snapshot.hasError || snapshot.data == null) return _missing();
          return Image.file(snapshot.data!, fit: widget.fit, gaplessPlayback: false,
            cacheWidth: 512, errorBuilder: (_, __, ___) => _missing());
        });
      });
  }
}
