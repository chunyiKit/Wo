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
        self.assertIn("UIGraphicsImageRenderer", self.ios)
        self.assertIn("clean.jpegData(compressionQuality:", self.ios)
        self.assertIn("out.size() <= MAX_THUMBNAIL", self.android)
        self.assertIn("bytes.count <= Self.maxThumbnail", self.ios)
        self.assertNotIn("ExifInterface", self.android)
        self.assertNotIn("CGImageDestinationAddImageFromSource", self.ios)

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
