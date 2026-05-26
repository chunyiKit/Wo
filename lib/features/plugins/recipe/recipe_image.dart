import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

/// 从相册选一张图并压缩成适合上传的 JPEG。
///
/// 压缩在「清晰度 / 体积」之间取平衡：
/// - 长边限制到 [maxEdge]（默认 1280）——菜谱封面够清楚，又不会动辄好几 MB；
/// - JPEG 质量 [quality]（默认 82）——肉眼几乎无损，体积通常压到 100–300KB。
///
/// 用户取消选择时返回 null。
Future<Uint8List?> pickAndCompressCover({
  int maxEdge = 1280,
  int quality = 82,
}) async {
  final picker = ImagePicker();
  final picked = await picker.pickImage(
    source: ImageSource.gallery,
    // image_picker 先做一次粗缩，降低后续压缩的内存峰值。
    maxWidth: 2400,
    maxHeight: 2400,
  );
  if (picked == null) return null;

  final raw = await picked.readAsBytes();
  final compressed = await FlutterImageCompress.compressWithList(
    raw,
    // minWidth/minHeight 在这里是「最长不超过」的上限（保持纵横比，不会放大）。
    minWidth: maxEdge,
    minHeight: maxEdge,
    quality: quality,
    format: CompressFormat.jpeg,
  );
  return compressed;
}
