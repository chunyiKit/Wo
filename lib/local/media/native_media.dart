import 'dart:typed_data';
import 'package:flutter/services.dart';

enum MediaKind { photo, video }
enum MediaSource { photos, files }

/// 只保存到本机 device_refs；绝不能将 handle 放进同步 payload 或日志。
class NativeMediaRef {
  final String handle;
  final MediaKind kind;
  final String contentType;
  final int size;
  final bool sourceExact;
  final String? missingReason;
  final int width;
  final int height;
  final int durationMs;

  const NativeMediaRef({required this.handle, required this.kind,
    required this.contentType, required this.size, required this.sourceExact,
    required this.missingReason, required this.width, required this.height,
    required this.durationMs});

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
  factory NativeMediaRef.fromMap(Map<dynamic, dynamic> map) {
    const fields = {'handle', 'kind', 'contentType', 'size', 'sourceExact',
      'missingReason', 'width', 'height', 'durationMs'};
    if (map.keys.toSet().difference(fields).isNotEmpty ||
        !fields.every(map.containsKey) || map['handle'] is! String ||
        !_uuid.hasMatch(map['handle'] as String) ||
        !{'photo', 'video'}.contains(map['kind']) ||
        map['contentType'] is! String || map['sourceExact'] is! bool ||
        !['size', 'width', 'height', 'durationMs'].every(
          (key) => map[key] is int && (map[key] as int) >= 0) ||
        (map['missingReason'] != null && map['missingReason'] is! String)) {
      throw const FormatException('原生媒体描述无效');
    }
    final exact = map['sourceExact'] as bool;
    final missing = map['missingReason'] as String?;
    if (exact && (missing != null || map['size'] == 0)) {
      throw const FormatException('原生媒体保真状态无效');
    }
    return NativeMediaRef(handle: map['handle'] as String,
      kind: map['kind'] == 'photo' ? MediaKind.photo : MediaKind.video,
      contentType: map['contentType'] as String, size: map['size'] as int,
      sourceExact: exact, missingReason: missing,
      width: map['width'] as int, height: map['height'] as int,
      durationMs: map['durationMs'] as int);
  }
}

class NativeMedia {
  static const channelName = 'wo.local/media';
  final MethodChannel channel;
  NativeMedia({MethodChannel? channel})
      : channel = channel ?? const MethodChannel(channelName);
  static const maxReadBytes = 8 * 1024 * 1024;
  static const maxThumbnailBytes = 96 * 1024;

  static void _checkHandle(String handle) {
    if (!NativeMediaRef._uuid.hasMatch(handle)) {
      throw ArgumentError('无效本机媒体引用');
    }
  }

  Future<NativeMediaRef?> pick({required MediaKind kind,
      required MediaSource source}) async {
    final map = await channel.invokeMapMethod<dynamic, dynamic>('pick',
      {'kind': kind.name, 'source': source.name});
    return map == null ? null : NativeMediaRef.fromMap(map);
  }

  Future<NativeMediaRef> resolve(String handle) async {
    _checkHandle(handle);
    final map = await channel.invokeMapMethod<dynamic, dynamic>(
      'resolve', {'handle': handle});
    if (map == null) throw StateError('本机媒体引用不可用');
    return NativeMediaRef.fromMap(map);
  }

  /// 用户显式备份时才准备原件；成功前不会将视频完整复制到私有目录。
  Future<NativeMediaRef> prepareOriginal(String handle) async {
    _checkHandle(handle);
    final map = await channel.invokeMapMethod<dynamic, dynamic>(
      'prepareOriginal', {'handle': handle});
    if (map == null) throw StateError('原件准备失败');
    return NativeMediaRef.fromMap(map);
  }

  /// 原件仅供电脑备份读取；不会为 sourceExact=false 回退读取脱敏流。
  Future<Uint8List> read(String handle, {required int offset,
      int maxBytes = 1024 * 1024}) async {
    _checkHandle(handle);
    if (offset < 0 || offset > 0x1fffffffffffff ||
        maxBytes < 1 || maxBytes > maxReadBytes) {
      throw ArgumentError('媒体分块范围无效');
    }
    final bytes = await channel.invokeMethod<Uint8List>('read',
      {'handle': handle, 'offset': offset, 'maxBytes': maxBytes});
    if (bytes == null || bytes.length > maxBytes) {
      throw StateError('原生媒体分块响应无效');
    }
    return bytes;
  }

  /// 同步只使用此无 EXIF 的小图，不附带 handle 或原图字节。
  Future<Uint8List> thumbnail(String handle) async {
    _checkHandle(handle);
    final bytes = await channel.invokeMethod<Uint8List>(
      'thumbnail', {'handle': handle});
    if (bytes == null || bytes.length < 4 ||
        bytes.length > maxThumbnailBytes || bytes[0] != 0xff || bytes[1] != 0xd8) {
      throw StateError('原生缩略图响应无效');
    }
    return bytes;
  }

  /// 用户显式点开时由原生本地预览，不把 URI 交给 Dart 或同步层。
  Future<bool> openOriginal(String handle) async {
    _checkHandle(handle);
    return await channel.invokeMethod<bool>('openOriginal', {'handle': handle}) == true;
  }

  Future<void> release(String handle) async {
    _checkHandle(handle);
    await channel.invokeMethod<void>('release', {'handle': handle});
  }
}
