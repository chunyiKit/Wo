import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

/// 从相册选一张图并压缩成适合上传的 JPEG。
///
/// - 长边限制到 [maxEdge]——足够清晰又不会动辄几 MB；
/// - JPEG 质量 [quality]——肉眼几乎无损。
///
/// 用户取消选择时返回 null。
Future<Uint8List?> pickAndCompressImage({
  int maxEdge = 1280,
  int quality = 82,
  ImageSource source = ImageSource.gallery,
}) async {
  final picker = ImagePicker();
  final picked = await picker.pickImage(
    source: source,
    // image_picker 先做一次粗缩，降低后续压缩的内存峰值。
    maxWidth: 2400,
    maxHeight: 2400,
  );
  if (picked == null) return null;

  final raw = await picked.readAsBytes();
  final compressed = await FlutterImageCompress.compressWithList(
    raw,
    // minWidth/minHeight 在这里是「最长不超过」的上限（保持纵横比，不放大）。
    minWidth: maxEdge,
    minHeight: maxEdge,
    quality: quality,
    format: CompressFormat.jpeg,
  );
  return compressed;
}
