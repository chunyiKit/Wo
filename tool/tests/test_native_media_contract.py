"""Privacy/streaming source contracts only; never invokes Dart, Flutter or SDKs."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
DART = ROOT / "lib/local/media/native_media.dart"
ANDROID = ROOT / "android/app/src/main/kotlin/io/github/chunyikit/wo/WoMediaBridge.kt"
IOS = ROOT / "ios/Runner/WoMediaBridge.swift"
DOC = ROOT / "docs/rebuild/NATIVE-MEDIA.md"


def body(source: str, start: str, stop: str) -> str:
    return source.split(start, 1)[1].split(stop, 1)[0]


def strip_encoder_jpeg(data: bytes) -> bytes:
    """Independent structural oracle; does not execute Kotlin/Swift or decode color."""
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        raise ValueError("SOI")
    output = bytearray(data[:2])
    position, in_scan, saw_scan = 2, False, False
    while position < len(data):
        if in_scan:
            start = position
            while position < len(data):
                if data[position] != 0xff:
                    position += 1
                    continue
                marker_start = position
                next_byte = position + 1
                while next_byte < len(data) and data[next_byte] == 0xff:
                    next_byte += 1
                if next_byte >= len(data):
                    raise ValueError("entropy marker truncated")
                marker = data[next_byte]
                if marker in (0, 1) or 0xd0 <= marker <= 0xd7:
                    position = next_byte + 1
                    continue
                output.extend(data[start:marker_start])
                position, in_scan = marker_start, False
                break
            else:
                raise ValueError("missing entropy EOI")
            continue
        start = position
        if data[position] != 0xff:
            raise ValueError("marker prefix")
        while position < len(data) and data[position] == 0xff:
            position += 1
        if position >= len(data):
            raise ValueError("marker truncated")
        marker = data[position]
        position += 1
        if marker == 0xd9:
            if not saw_scan or position != len(data):
                raise ValueError("EOI/trailing")
            output.extend(data[start:position])
            return bytes(output)
        if marker in (0, 0xd8) or 0xd0 <= marker <= 0xd7:
            raise ValueError("unexpected standalone marker")
        if marker == 1:
            output.extend(data[start:position])
            continue
        if len(data) - position < 2:
            raise ValueError("length truncated")
        length = int.from_bytes(data[position:position + 2], "big")
        if length < 2 or length > len(data) - position:
            raise ValueError("length out of bounds")
        end = position + length
        if not (0xe1 <= marker <= 0xef or marker == 0xfe):
            output.extend(data[start:end])
        position = end
        if marker == 0xda:
            in_scan = saw_scan = True
    raise ValueError("no EOI")


def jpeg_segment(marker: int, payload: bytes) -> bytes:
    return b"\xff" + bytes([marker]) + (len(payload) + 2).to_bytes(2, "big") + payload


class NativeMediaContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dart, cls.android, cls.ios = [p.read_text() for p in (DART, ANDROID, IOS)]

    def test_channel_and_injectable_instance_api_are_shared(self):
        for source in (self.dart, self.android, self.ios):
            self.assertIn("wo.local/media", source)
            for method in ("pick", "resolve", "prepareOriginal", "read", "thumbnail", "release", "openOriginal"):
                self.assertIn(method, source)
        self.assertIn("NativeMedia({MethodChannel? channel})", self.dart)
        self.assertNotIn("static Future<", self.dart)
        self.assertIn("fun attach(activity: Activity, messenger: BinaryMessenger)", self.android)
        self.assertIn("static func attach(messenger: FlutterBinaryMessenger", self.ios)

    def test_descriptor_has_only_safe_keys_and_strict_dart_decoder(self):
        expected = {"handle", "kind", "contentType", "size", "sourceExact", "missingReason", "width", "height", "durationMs"}
        declared = body(self.dart, "const fields = {", "};")
        self.assertEqual(set(re.findall(r"'([^']+)'", declared)), expected)
        self.assertIn("map.keys.toSet().difference(fields)", self.dart)
        for source, start, stop in ((self.android, 'val out = mutableMapOf<String, Any?>(', '\n        try {'), (self.ios, 'var out: [String: Any] = [', '\n    let file')):
            descriptor = body(source, start, stop)
            keys = set(re.findall(r'"([A-Za-z]+)"\s*(?:to|:)', descriptor))
            self.assertEqual(keys, expected)
            self.assertNotIn("assetIdentifier", descriptor)
            self.assertNotIn("bookmark", descriptor)
            self.assertNotIn('"uri"', descriptor)

    def test_pick_and_resolve_do_not_read_or_copy_whole_original(self):
        android = body(self.android, "private fun pick(", "private fun isTrustedLocal(")
        ios = body(self.ios, "private func pick(", "private func base(")
        for source in (android, ios):
            self.assertNotIn("readBytes(", source)
            self.assertNotIn("prepareOriginal(", source)
            self.assertNotIn("requestData(for:", source)
        ios_resolve = body(self.ios, "private func resolve(", "private func prepareOriginal(")
        self.assertNotIn("requestData", ios_resolve)
        self.assertNotIn("value(forKey:", self.ios)
        self.assertNotIn("valueForKey", self.ios)
        self.assertIn('"size": 0', ios_resolve)

    def test_android_exact_requires_local_provider_permission_and_original_codec(self):
        exact = body(self.android, "private fun exactUri(", "private fun resolve(")
        for guard in ("localUri(ref)", "Build.VERSION.SDK_INT < 29", "ACCESS_MEDIA_LOCATION", "PackageManager.PERMISSION_GRANTED", "MediaStore.getMediaUri", "MediaStore.setRequireOriginal"):
            self.assertIn(guard, exact)
        self.assertIn("isMediaStoreItem", self.android)
        self.assertIn("FLAG_SYSTEM", self.android)
        self.assertIn("FLAG_VIRTUAL_DOCUMENT", self.android)
        self.assertIn("Intent.EXTRA_LOCAL_ONLY, true", self.android)
        self.assertIn("takePersistableUriPermission", self.android)
        self.assertIn("getOriginalMediaFormatFileDescriptor", self.android)
        self.assertNotIn("READ_MEDIA_IMAGES", self.android)
        self.assertNotIn("ACCESS_FINE_LOCATION", self.android)
        self.assertNotIn("Log.", self.android)

    def test_ios_uses_public_original_resources_and_forbids_network(self):
        for guard in ("PHPickerViewController", "requestAuthorization(for: .readWrite)", "PHAssetResource.assetResources", "PHAssetResourceType", ".photo : .video", "candidates.count == 1", "isNetworkAccessAllowed = false", "PHPhotosError.Code.networkAccessRequired"):
            self.assertIn(guard, self.ios)
        self.assertNotIn("isNetworkAccessAllowed = true", self.ios)
        for forbidden in ("AVAssetExportSession", "startDownloadingUbiquitousItem", "loadFileRepresentation", "loadObject(ofClass:", "print(", "NSLog("):
            self.assertNotIn(forbidden, self.ios)
        self.assertIn("startAccessingSecurityScopedResource()", self.ios)
        self.assertIn("stopAccessingSecurityScopedResource()", self.ios)
        self.assertIn("bookmarkData(options: .minimalBookmark", self.ios)
        self.assertIn("ubiquitousItemDownloadingStatus", self.ios)
        self.assertIn('throw fail("not_on_device")', self.ios)

    def test_snapshot_is_streamed_private_and_proof_published_last(self):
        self.assertIn("activity.noBackupFilesDir", self.android)
        self.assertIn("AtomicFile", self.android)
        self.assertIn(".applicationSupportDirectory", self.ios)
        self.assertIn("isExcludedFromBackup = true", self.ios)
        self.assertIn("isExcludedFromBackup == true", self.ios)
        self.assertIn("64 * 1024", self.android)
        self.assertIn("64 * 1024", self.ios)
        self.assertIn("MessageDigest.getInstance(\"SHA-256\")", self.android)
        self.assertIn("var digest = SHA256()", self.ios)
        a = body(self.android, "private fun prepareOriginal(", "private fun verifySnapshot(")
        self.assertLess(a.index('ref.remove("snapshotSHA256")'), a.index("exactUri(ref)"))
        self.assertLess(a.index("temporary.renameTo(snapshot(handle))"), a.index('ref.put("contentType", mime).put("snapshotSize"'))
        i = body(self.ios, "private func prepareOriginal(", "private func snapshotSignature(")
        self.assertLess(i.index('ref.removeValue(forKey: "snapshotSHA256")'), i.index("requestData(for:"))
        self.assertLess(i.index("replaceItemAt(target"), i.index('ref["snapshotSize"] = NSNumber'))

    def test_read_uses_authenticated_snapshot_and_enforces_chunk_bounds(self):
        self.assertIn("maxReadBytes = 8 * 1024 * 1024", self.dart)
        self.assertIn("MAX_READ = 8 * 1024 * 1024", self.android)
        self.assertIn("maxRead = 8 * 1024 * 1024", self.ios)
        for source, start, stop in ((self.android, "private fun read(", "private fun thumbnail("), (self.ios, "private func read(", "private func openOriginal(")):
            read = body(source, start, stop)
            self.assertIn("snapshotSHA256", read)
            self.assertIn("verifySnapshot", read)
            self.assertNotIn("contentResolver", read)
            self.assertNotIn("requestData", read)
        self.assertIn("read(upToCount: min(count", self.ios)
        self.assertIn("ByteArray(minOf(count.toLong()", self.android)

    def test_thumbnails_are_fresh_pixels_with_hard_budget(self):
        for source in (self.dart, self.android, self.ios):
            self.assertIn("96 * 1024", source)
        self.assertIn("Bitmap.CompressFormat.JPEG", self.android)
        self.assertIn("CGColorSpace(name: CGColorSpace.sRGB)", self.ios)
        self.assertIn("clean.jpegData(compressionQuality:", self.ios)
        self.assertIn("bytes.size <= MAX_THUMBNAIL", self.android)
        self.assertIn("bytes.count <= Self.maxThumbnail", self.ios)
        self.assertNotIn("ExifInterface", self.android)
        self.assertNotIn("CGImageDestinationAddImageFromSource", self.ios)

    def test_thumbnail_srgb_conversion_precedes_fresh_encode_and_private_sanitizer(self):
        self.assertIn("ColorSpace.get(ColorSpace.Named.SRGB)", self.android)
        self.assertIn("Canvas(clean)", self.android)
        self.assertIn("Bitmap.Config.ARGB_8888", self.android)
        self.assertIn("CGColorSpace(name: CGColorSpace.sRGB)", self.ios)
        self.assertIn("bitsPerComponent: 8", self.ios)
        self.assertIn("space: srgb", self.ios)
        self.assertEqual(self.android.count("stripThumbnailMetadata("), 2)
        self.assertEqual(self.ios.count("stripThumbnailMetadata("), 2)
        for source in (self.android, self.ios):
            thumb = body(source, "private " + ("fun" if source is self.android else "func") + " thumbnail(", "private " + ("fun" if source is self.android else "func") + " stripThumbnailMetadata(")
            self.assertLess(thumb.index("clean."), thumb.index("stripThumbnailMetadata("))
        self.assertIn("fun close()", self.android)
        self.assertIn("marker !in 0xe1..0xef && marker != 0xfe", self.android)
        self.assertIn("!(0xe1...0xef).contains(marker) && marker != 0xfe", self.ios)
        for source in (self.android, self.ios):
            self.assertIn("length", source)
            self.assertIn("sawScan", source)
            self.assertIn("0xd0", source)
            self.assertIn("0x00", source)

    def test_jpeg_oracle_strips_icc_exif_comments_and_preserves_entropy_and_all_scans(self):
        soi, eoi = b"\xff\xd8", b"\xff\xd9"
        app0 = jpeg_segment(0xe0, b"JFIF\x00")
        frame = jpeg_segment(0xc0, b"synthetic frame")
        scan = jpeg_segment(0xda, b"synthetic scan header")
        entropy1 = b"\x11\xff\x00\x22\xff\xd0\x33\xff\xff\xd7\x44\xff\x01\x55"
        entropy2 = b"\x66\xff\x00\xe2\x77"
        metadata = b"".join(jpeg_segment(marker, b"private\xff\xd9ICC_PROFILE\x00") for marker in range(0xe1, 0xf0)) + jpeg_segment(0xfe, b"comment")
        encoded = soi + app0 + metadata + frame + scan + entropy1 + metadata + scan + entropy2 + eoi
        expected = soi + app0 + frame + scan + entropy1 + scan + entropy2 + eoi
        self.assertEqual(strip_encoder_jpeg(encoded), expected)
        self.assertEqual(strip_encoder_jpeg(expected), expected)
        self.assertNotIn(b"ICC_PROFILE", strip_encoder_jpeg(encoded))

    def test_jpeg_oracle_fails_closed_on_segment_bounds_or_truncated_entropy(self):
        soi, eoi = b"\xff\xd8", b"\xff\xd9"
        scan = jpeg_segment(0xda, b"scan")
        valid = soi + scan + b"entropy\xff\x00" + eoi
        cases = [b"", b"not JPEG", soi + eoi, valid[:-1], valid[:-2], valid + b"extra",
                 soi + b"\xff\xe2\x00\x01", soi + b"\xff\xe2\xff\xffshort",
                 soi + b"\xff\xe2\x00", soi + b"\xff\xd8" + scan + eoi,
                 soi + scan + b"entropy\xff", soi + scan + b"\xff\xff"]
        for encoded in cases:
            with self.subTest(encoded=encoded), self.assertRaises(ValueError):
                strip_encoder_jpeg(encoded)

    def test_release_does_not_delete_user_source_or_revoke_shared_grants(self):
        self.assertNotIn("contentResolver.delete", self.android)
        self.assertNotIn("releasePersistableUriPermission", self.android)
        self.assertNotIn("PHAssetChangeRequest", self.ios)
        self.assertNotIn("removeItem(at: url)", self.ios)
        self.assertIn("snapshot(handle!!).delete()", self.android)
        self.assertIn("removeItem(at: snapshot)", self.ios)

    def test_preview_and_documentation_are_honest_about_native_validation(self):
        self.assertIn("Intent.ACTION_VIEW", self.android)
        self.assertIn("Intent.FLAG_GRANT_READ_URI_PERMISSION", self.android)
        self.assertIn("PHVideoRequestOptions", self.ios)
        self.assertIn("local.url.isFileURL", self.ios)
        self.assertIn("result(false)", self.ios)
        doc = DOC.read_text()
        for term in ("未原生编译", "未运行", "iOS 14.0", "第三方 FileProvider", "独立", "SHA", "Kotlin/Swift/Dart"):
            self.assertIn(term, doc)


if __name__ == "__main__":
    unittest.main()
