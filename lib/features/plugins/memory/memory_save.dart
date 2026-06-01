import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../../../data/models.dart';

/// 大图页长按 → 把这张图存进系统相册（Android 走 MediaStore，iOS 走 Photos）。
///
/// 复用 [CachedNetworkImage] 留下的本地缓存文件——这张图在大图页能显示出来,就一定
/// 已经被 [DefaultCacheManager] 缓存过,这里直接捞,不会触发第二次网络下载。
///
/// gal 是按文件后缀推断 MIME 的,而后端 `/raw` 返回的 URL 不带扩展名 → 缓存文件
/// 也没扩展名。我们按 [MemoryMedia.contentType] 把缓存文件拷一份到带正确后缀的
/// 临时文件再交给 gal,保存成功后清理临时副本。
///
/// 返回错误提示字符串;`null` 表示保存成功。
Future<String?> saveMemoryImageToGallery({
  required MemoryMedia media,
  required String url,
  required Map<String, String> headers,
}) async {
  if (media.isVideo) return '暂不支持保存视频';

  // 权限。`requestAccess(toAlbum: true)` 在 iOS 上请求的是「仅添加」权限
  // (NSPhotoLibraryAddUsageDescription),Android 在 API 29+ 不需要任何权限。
  try {
    final ok = await Gal.hasAccess(toAlbum: true) ||
        await Gal.requestAccess(toAlbum: true);
    if (!ok) return '需要相册权限才能保存';
  } on GalException catch (e) {
    return '获取相册权限失败：${e.type.message}';
  }

  // 从 cached_network_image 的缓存里捞到这张图的本地副本。命中缓存时同步返回;
  // 偶发未命中会触发一次重新下载,但不带鉴权头会失败——这里仍传 headers 兜底。
  File cached;
  try {
    cached = await DefaultCacheManager().getSingleFile(url, headers: headers);
  } catch (_) {
    return '下载失败';
  }

  // 改名带正确扩展,只是为了让 gal 写进相册时类型识别正确;原缓存文件不动。
  final ext = _extFromContentType(media.contentType);
  final tmpDir = await getTemporaryDirectory();
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final target = File('${tmpDir.path}/wo-memory-$stamp.$ext');
  try {
    await cached.copy(target.path);
  } catch (_) {
    return '准备文件失败';
  }

  try {
    await Gal.putImage(target.path, album: '窝');
  } on GalException catch (e) {
    return '保存失败：${e.type.message}';
  } finally {
    // 临时副本写成功 / 失败都尽力清掉,失败也不影响主流程。
    try {
      if (await target.exists()) await target.delete();
    } catch (_) {}
  }
  return null;
}

String _extFromContentType(String contentType) {
  switch (contentType.toLowerCase()) {
    case 'image/png':
      return 'png';
    case 'image/webp':
      return 'webp';
    case 'image/gif':
      return 'gif';
    default:
      // 上传时统一压成 JPEG,所以未识别类型按 jpg 兜底。
      return 'jpg';
  }
}
