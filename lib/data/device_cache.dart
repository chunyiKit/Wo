import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

/// 本机各类存储占用的一次测算结果（单位：字节）。
///
/// 三类相加即「应用占用大小」：
/// - [dataCacheBytes]：图片 / 临时文件缓存，**可清理**（见 [DeviceCacheService.clearDataCache]）。
/// - [apkBytes]：检查更新时下载的历史安装包，**可清理**（见 [DeviceCacheService.clearApks]）。
/// - [appDataBytes]：登录态、设置等核心数据，不在本页清理范围内。
class CacheUsage {
  const CacheUsage({
    required this.dataCacheBytes,
    required this.apkBytes,
    required this.appDataBytes,
  });

  final int dataCacheBytes;
  final int apkBytes;
  final int appDataBytes;

  int get totalBytes => dataCacheBytes + apkBytes + appDataBytes;

  static const empty =
      CacheUsage(dataCacheBytes: 0, apkBytes: 0, appDataBytes: 0);
}

/// 字节数转人类可读字符串（B / KB / MB / GB / TB）。
/// B 不带小数；其余保留 1 位小数（≥100 时取整更清爽）。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final text = unit == 0
      ? size.toStringAsFixed(0)
      : (size >= 100 ? size.toStringAsFixed(0) : size.toStringAsFixed(1));
  return '$text ${units[unit]}';
}

/// 测算与清理本机缓存。所有方法对 IO 异常宽容（单个文件失败不影响整体），
/// 因为缓存清理是「尽力而为」，不能因为某个被占用的文件就整体失败。
///
/// 与 [AppUpdateService] 约定一致：下载的 APK 落在
/// [getApplicationSupportDirectory] 下，文件名形如 `wo-<versionCode>.apk`。
class DeviceCacheService {
  /// APK 文件名规则，与 [AppUpdateService.downloadApk] 的落盘命名保持一致。
  static final _apkPattern = RegExp(r'^wo-\d+\.apk$');

  /// 测算三类占用。任何目录读不到都按 0 计，不抛异常。
  Future<CacheUsage> measure() async {
    final tmp = await _safeDir(getTemporaryDirectory);
    final support = await _safeDir(getApplicationSupportDirectory);
    final docs = await _safeDir(getApplicationDocumentsDirectory);

    final apkBytes = await _sumFiles(_apkFiles(support));
    final dataCacheBytes = await _dirSize(tmp);

    // support 目录里除安装包外的部分 + documents 目录，一并算作「应用数据」。
    final supportTotal = await _dirSize(support);
    final docsBytes = await _dirSize(docs);
    final supportOther = (supportTotal - apkBytes).clamp(0, supportTotal);
    final appDataBytes = supportOther + docsBytes;

    return CacheUsage(
      dataCacheBytes: dataCacheBytes,
      apkBytes: apkBytes,
      appDataBytes: appDataBytes,
    );
  }

  /// 清理图片 / 临时文件缓存：
  /// 1. 清空 flutter_cache_manager（图片磁盘缓存 + 索引）；
  /// 2. 清空内存图片缓存，避免清盘后旧图仍占内存；
  /// 3. 删除临时目录下的其余临时文件（选图 / 压缩 / 视频等中间产物）。
  Future<void> clearDataCache() async {
    try {
      await DefaultCacheManager().emptyCache();
    } catch (_) {
      // 缓存管理器索引被占用等情况忽略，继续清临时目录。
    }
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    final tmp = await _safeDir(getTemporaryDirectory);
    if (tmp != null) await _clearDir(tmp);
  }

  /// 删除所有历史下载的安装包（APK）。删除后再次「检查更新」会重新下载。
  Future<void> clearApks() async {
    final support = await _safeDir(getApplicationSupportDirectory);
    for (final f in _apkFiles(support)) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {
        // 单个文件被占用 / 已删等忽略。
      }
    }
  }

  // ── 内部工具 ────────────────────────────────────────────────────

  Future<Directory?> _safeDir(Future<Directory> Function() get) async {
    try {
      final dir = await get();
      return await dir.exists() ? dir : null;
    } catch (_) {
      return null;
    }
  }

  /// 列出 [support] 下符合命名规则的 APK 文件（不递归）。
  List<File> _apkFiles(Directory? support) {
    if (support == null) return const [];
    try {
      return support
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => _apkPattern.hasMatch(_basename(f.path)))
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<int> _sumFiles(List<File> files) async {
    var total = 0;
    for (final f in files) {
      try {
        total += await f.length();
      } catch (_) {
        // 忽略读不到长度的文件。
      }
    }
    return total;
  }

  /// 递归统计目录占用字节数。遇到任何 IO 错误都跳过该项，不中断统计。
  Future<int> _dirSize(Directory? dir) async {
    if (dir == null) return 0;
    var total = 0;
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {
            // 单个文件读不到长度（已删/无权限）跳过。
          }
        }
      }
    } catch (_) {
      // 目录遍历失败，返回已累计的部分。
    }
    return total;
  }

  /// 逐项删除目录下的内容（不删目录本身），单项失败不影响其余。
  Future<void> _clearDir(Directory dir) async {
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final entity in entries) {
      try {
        await entity.delete(recursive: true);
      } catch (_) {
        // 占用中 / 无权限的项跳过。
      }
    }
  }

  String _basename(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    return i < 0 ? path : path.substring(i + 1);
  }
}
