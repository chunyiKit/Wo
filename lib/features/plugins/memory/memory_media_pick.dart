import 'dart:io';
import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

/// 选好待上传的一段视频：原始字节 + 文件名 + 时长（毫秒，读不到则 null）。
class PickedVideo {
  const PickedVideo({
    required this.bytes,
    required this.filename,
    this.durationMs,
  });

  final Uint8List bytes;
  final String filename;
  final int? durationMs;
}

/// 选好的一批照片：压缩后的字节 + 第一张的 EXIF 拍摄日期（读不到为 null）。
///
/// 拍摄日期从压缩前的原图读取——压缩会丢掉 EXIF，所以必须在压缩前取。
class PickedPhotos {
  const PickedPhotos({required this.photos, this.firstCapturedAt});

  final List<Uint8List> photos;
  final DateTime? firstCapturedAt;

  bool get isEmpty => photos.isEmpty;
}

/// 从相册一次选多张照片并压缩成 JPEG。用户取消返回空结果。
///
/// - 长边压到 [maxEdge]（回忆照片比菜谱封面更想留细节，默认略大）；
/// - [limit] 限制单次最多选几张（剩余可再点一次九宫格补选）；
/// - 顺带读出第一张照片的 EXIF 拍摄日期，供新建时自动填日期用。
Future<PickedPhotos> pickAndCompressMemoryPhotos({
  int maxEdge = 1600,
  int quality = 82,
  int? limit,
}) async {
  final picker = ImagePicker();
  final picked = await picker.pickMultiImage(limit: limit);
  final out = <Uint8List>[];
  DateTime? firstCapturedAt;
  for (var i = 0; i < picked.length; i++) {
    final raw = await picked[i].readAsBytes();
    if (i == 0) firstCapturedAt = await _readExifCaptureDate(raw);
    final compressed = await FlutterImageCompress.compressWithList(
      raw,
      minWidth: maxEdge,
      minHeight: maxEdge,
      quality: quality,
      format: CompressFormat.jpeg,
    );
    out.add(compressed);
  }
  return PickedPhotos(photos: out, firstCapturedAt: firstCapturedAt);
}

/// 从图片字节里读 EXIF 拍摄日期（DateTimeOriginal，退到 Image DateTime）。
/// 只取到「天」即可，因为回忆的 event_date 是日期。读不到返回 null。
Future<DateTime?> _readExifCaptureDate(Uint8List bytes) async {
  try {
    final tags = await readExifFromBytes(bytes);
    final tag = tags['EXIF DateTimeOriginal'] ??
        tags['EXIF DateTimeDigitized'] ??
        tags['Image DateTime'];
    if (tag == null) return null;
    return _parseExifDate(tag.printable);
  } catch (_) {
    // 不是 JPEG / 没有 EXIF / 解析失败都不致命，回退到默认「今天」。
    return null;
  }
}

/// EXIF 日期格式固定为 "YYYY:MM:DD HH:MM:SS"，这里只解析年月日。
DateTime? _parseExifDate(String raw) {
  final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})').firstMatch(raw.trim());
  if (m == null) return null;
  final year = int.tryParse(m.group(1)!);
  final month = int.tryParse(m.group(2)!);
  final day = int.tryParse(m.group(3)!);
  if (year == null || month == null || day == null) return null;
  if (year < 1970 || month < 1 || month > 12 || day < 1 || day > 31) return null;
  return DateTime(year, month, day);
}

/// 从相册选一段视频。时长用一次性初始化的播放器读出（读不到不致命）。
/// 用户取消返回 null。
Future<PickedVideo?> pickMemoryVideo() async {
  final picker = ImagePicker();
  final picked = await picker.pickVideo(source: ImageSource.gallery);
  if (picked == null) return null;

  final bytes = await picked.readAsBytes();
  int? durationMs;
  final controller = VideoPlayerController.file(File(picked.path));
  try {
    await controller.initialize();
    final d = controller.value.duration;
    if (d > Duration.zero) durationMs = d.inMilliseconds;
  } catch (_) {
    // 读不到时长就算了，上传仍可进行。
  } finally {
    await controller.dispose();
  }
  return PickedVideo(bytes: bytes, filename: picked.name, durationMs: durationMs);
}
