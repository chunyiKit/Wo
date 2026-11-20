package io.github.chunyikit.wo

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.AtomicFile
import android.util.Size
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors

/** Stable device-only references. Never logs URI, display name, handle or bytes. */
class WoMediaBridge private constructor(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "wo.local/media"
        private const val PICK_REQUEST = 48171
        private const val LOCATION_REQUEST = 48172
        private const val MAX_READ = 8 * 1024 * 1024
        private const val MAX_THUMBNAIL = 96 * 1024
        fun attach(activity: Activity, messenger: BinaryMessenger) = WoMediaBridge(activity, messenger)
    }
    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    // noBackupFilesDir is deliberately used rather than default backed-up preferences.
    private val registryFile = AtomicFile(File(activity.noBackupFilesDir, "wo-media-device-refs.json"))
    private var registry: JSONObject? = null
    private val verifiedSnapshots = mutableMapOf<String, String>()
    private var pending: MethodChannel.Result? = null
    private var pendingKind = "photo"
    private var pendingSource = "photos"
    private var pickedUri: Uri? = null
    private var pickedStable = false
    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "pick") { pick(call, result); return }
        val handle = call.argument<String>("handle")
        if (!validHandle(handle)) { result.error("MEDIA_ARGUMENT", "本机媒体引用无效", null); return }
        if (call.method !in setOf("resolve", "prepareOriginal", "openOriginal", "read", "thumbnail", "release")) { result.notImplemented(); return }
        if (call.method == "openOriginal") {
            worker.execute {
                val target = try {
                    val ref = refs().optJSONObject(handle!!) ?: throw MediaFailure("source_missing")
                    val selected = localUri(ref)
                    activity.contentResolver.openFileDescriptor(selected, "r")?.use { if (it.statSize < 1) throw MediaFailure("source_unavailable") } ?: throw MediaFailure("source_missing")
                    Pair(selected, activity.contentResolver.getType(selected))
                } catch (_: Exception) { null }
                main.post {
                    if (target == null) { result.success(false) }
                    else try {
                        val intent = Intent(Intent.ACTION_VIEW).apply { setDataAndType(target.first, target.second); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                        activity.startActivity(intent); result.success(true)
                    } catch (_: Exception) { result.success(false) }
                }
            }
            return
        }
        val rawOffset = call.argument<Number>("offset")
        val rawCount = call.argument<Number>("maxBytes")
        val offset = rawOffset?.toLong() ?: -1L
        val count = rawCount?.toLong() ?: -1L
        if (call.method == "read" && (offset < 0 || offset > 9007199254740991L || count < 1 || count > MAX_READ ||
            rawOffset?.toDouble() != offset.toDouble() || rawCount?.toDouble() != count.toDouble())) {
            result.error("MEDIA_ARGUMENT", "媒体分块范围无效", null); return
        }
        async(result) {
            val refs = refs()
            if (call.method == "release") {
                // Delete only this private registry reference. Other references may share a grant.
                refs.remove(handle); save(refs); verifiedSnapshots.remove(handle); snapshot(handle!!).delete(); null
            } else {
                val ref = refs.optJSONObject(handle!!) ?: throw MediaFailure("source_missing")
                when (call.method) {
                    "resolve" -> resolve(handle, ref)
                    "prepareOriginal" -> prepareOriginal(handle, ref)
                    "read" -> read(handle, ref, offset, count.toInt())
                    "thumbnail" -> thumbnail(ref)
                    else -> null
                }
            }
        }
    }

    private fun pick(call: MethodCall, result: MethodChannel.Result) {
        val kind = call.argument<String>("kind")
        val source = call.argument<String>("source")
        if (kind !in setOf("photo", "video") || source !in setOf("photos", "files")) {
            result.error("MEDIA_ARGUMENT", "媒体选择参数无效", null); return
        }
        if (pending != null) { result.error("MEDIA_BUSY", "请先完成当前媒体选择", null); return }
        pending = result; pendingKind = kind!!; pendingSource = source!!
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (kind == "photo") "image/*" else "video/*"
            putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try { activity.startActivityForResult(intent, PICK_REQUEST) }
        catch (_: Exception) { finishError("source_unavailable") }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQUEST) return false
        if (pending == null) return true
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { finish(null); return true }
        if (uri.scheme != "content") { finishError("unsupported"); return true }
        pickedUri = uri; pickedStable = false
        try {
            if ((data?.flags ?: 0) and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0) {
                activity.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                pickedStable = true
            }
        } catch (_: SecurityException) { /* non-persistent selection remains explicitly incomplete */ }
        // This is metadata fidelity consent only; no broad library or device-location permission.
        if (isTrustedLocal(uri) && Build.VERSION.SDK_INT >= 29 &&
            activity.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            try { activity.requestPermissions(arrayOf(Manifest.permission.ACCESS_MEDIA_LOCATION), LOCATION_REQUEST) }
            catch (_: Exception) { storeSelection() }
        } else { storeSelection() }
        return true
    }

    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != LOCATION_REQUEST) return false
        if (pending != null) storeSelection()
        return true
    }

    private fun storeSelection() {
        val result = pending ?: return
        val uri = pickedUri ?: run { finishError("source_missing"); return }
        val kind = pendingKind; val source = pendingSource; val stable = pickedStable
        pending = null; pickedUri = null
        async(result) {
            val handle = UUID.randomUUID().toString()
            val ref = JSONObject().put("uri", uri.toString()).put("kind", kind)
                .put("source", source).put("stable", stable)
            val all = refs(); all.put(handle, ref); save(all)
            resolve(handle, ref)
        }
    }

    private fun isTrustedLocal(uri: Uri): Boolean {
        val authority = uri.authority ?: return false
        if (authority !in setOf("media", "com.android.providers.media.documents", "com.android.externalstorage.documents", "com.android.providers.downloads.documents")) return false
        if (authority == "media" && !isMediaStoreItem(uri)) return false // exclude cloud picker proxy routes
        val info = activity.packageManager.resolveContentProvider(authority, 0) ?: return false
        return info.applicationInfo.flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
    }

    private fun isMediaStoreItem(uri: Uri): Boolean {
        val p = uri.pathSegments
        return p.size == 4 && p[0].isNotEmpty() && p[1] in setOf("images", "video") && p[2] == "media" && (p[3].toLongOrNull() ?: -1L) >= 0L
    }
    private fun uri(ref: JSONObject): Uri = Uri.parse(ref.getString("uri"))
    private fun localUri(ref: JSONObject): Uri {
        val uri = uri(ref)
        if (!ref.optBoolean("stable")) throw MediaFailure("permission_denied")
        if (!isTrustedLocal(uri)) throw MediaFailure("source_unavailable")
        if (DocumentsContract.isDocumentUri(activity, uri)) {
            activity.contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst() && Build.VERSION.SDK_INT >= 24 && cursor.getInt(0) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT != 0) throw MediaFailure("unsupported")
            }
        }
        return uri
    }

    private fun exactUri(ref: JSONObject): Uri {
        val selected = localUri(ref)
        if (Build.VERSION.SDK_INT < 29) throw MediaFailure("source_not_exact")
        if (activity.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) != PackageManager.PERMISSION_GRANTED) throw MediaFailure("permission_denied")
        // Files SAF paths may also pass through redacting MediaProvider/FUSE. Never
        // label their raw openInputStream as exact without this original-media path.
        val media = if (selected.authority == "media") selected else MediaStore.getMediaUri(activity, selected)
        if (media == null || media.authority != "media" || !isMediaStoreItem(media)) throw MediaFailure("source_not_exact")
        return MediaStore.setRequireOriginal(media)
    }

    private fun resolve(handle: String, ref: JSONObject): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>("handle" to handle, "kind" to ref.getString("kind"), "contentType" to "", "size" to 0L,
            "sourceExact" to false, "missingReason" to "source_unavailable", "width" to 0, "height" to 0, "durationMs" to 0L)
        try {
            val ready = snapshot(handle)
            if (ref.optString("snapshotSHA256").matches(Regex("[a-f0-9]{64}")) && ready.isFile && ready.length() == ref.optLong("snapshotSize", -1L)) {
                out["size"] = ready.length(); out["contentType"] = ref.optString("contentType")
                if (ref.getString("kind") == "photo") {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(ready.absolutePath, bounds)
                    out["width"] = bounds.outWidth.coerceAtLeast(0); out["height"] = bounds.outHeight.coerceAtLeast(0)
                } else {
                    val retriever = MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(ready.absolutePath)
                        out["width"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                        out["height"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                        out["durationMs"] = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                    } finally { retriever.release() }
                }
                out["sourceExact"] = true; out["missingReason"] = null
            } else {
                val selected = localUri(ref)
                out["contentType"] = activity.contentResolver.getType(selected) ?: ""
                exactUri(ref) // consent/provenance check only; no original is opened or copied
                out["missingReason"] = "not_prepared"
            }
        } catch (failure: Exception) { out["sourceExact"] = false; out["missingReason"] = reason(failure) }
        return out
    }

    private fun snapshot(handle: String): File = File(activity.noBackupFilesDir, "wo-original-$handle.snapshot")

    private fun prepareOriginal(handle: String, ref: JSONObject): Map<String, Any?> {
        ref.remove("snapshotSHA256"); ref.remove("snapshotSize"); save(refs())
        val original = exactUri(ref)
        val mime = activity.contentResolver.getType(localUri(ref)) ?: ""
        if (!mime.startsWith(if (ref.getString("kind") == "photo") "image/" else "video/")) throw MediaFailure("unsupported")
        val temporary = File.createTempFile("wo-original-", ".partial", activity.noBackupFilesDir)
        try {
            var length = 0L
            val digest = MessageDigest.getInstance("SHA-256")
            activity.contentResolver.openFileDescriptor(original, "r")?.use { raw ->
                // Android 12+ may transcode HDR/HEVC even when EXIF is unredacted.
                val originalPfd = if (Build.VERSION.SDK_INT >= 31) MediaStore.getOriginalMediaFormatFileDescriptor(activity, raw) else raw
                ParcelFileDescriptor.AutoCloseInputStream(originalPfd).use { input ->
                    val before = android.system.Os.fstat(input.fd)
                    FileOutputStream(temporary).use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            length += count
                            if (length > 20L * 1024 * 1024 * 1024) throw MediaFailure("size_limit")
                            output.write(buffer, 0, count); digest.update(buffer, 0, count)
                        }
                        output.fd.sync()
                    }
                    val after = android.system.Os.fstat(input.fd)
                    if (before.st_size != after.st_size || before.st_mtime != after.st_mtime || before.st_size != length || length <= 0) throw MediaFailure("source_changed")
                }
            } ?: throw MediaFailure("source_missing")
            // Both paths are in the same no-backup private directory. Replace only
            // this app-owned snapshot, never the user source or a caller path.
            if (!temporary.renameTo(snapshot(handle))) throw MediaFailure("source_unavailable")
            ref.put("contentType", mime).put("snapshotSize", length).put("snapshotSHA256", digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) })
            save(refs())
            val file = snapshot(handle)
            verifiedSnapshots[handle] = "${file.length()}:${file.lastModified()}:${ref.getString("snapshotSHA256")}"
            return resolve(handle, ref)
        } finally { temporary.delete() }
    }

    private fun verifySnapshot(handle: String, ref: JSONObject) {
        val file = snapshot(handle)
        val expected = ref.optString("snapshotSHA256")
        val signature = "${file.length()}:${file.lastModified()}:$expected"
        if (verifiedSnapshots[handle] == signature) return
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
        if (actual != expected || file.length() != ref.optLong("snapshotSize", -1L)) throw MediaFailure("source_changed")
        verifiedSnapshots[handle] = signature
    }

    private fun read(handle: String, ref: JSONObject, offset: Long, count: Int): ByteArray {
        // Consent/provenance is checked at prepare, then reads use the immutable
        // app-private snapshot rather than repeatedly opening a changing provider.
        if (!ref.optString("snapshotSHA256").matches(Regex("[a-f0-9]{64}"))) throw MediaFailure("not_prepared")
        val file = snapshot(handle)
        val length = ref.optLong("snapshotSize", -1L)
        if (!file.isFile || length <= 0 || file.length() != length) throw MediaFailure("source_changed")
        verifySnapshot(handle, ref)
        if (offset > length) throw MediaFailure("source_changed")
        return FileInputStream(file).use { stream ->
            stream.channel.position(offset)
            val data = ByteArray(minOf(count.toLong(), length - offset).toInt())
            var received = 0
            while (received < data.size) {
                val n = stream.read(data, received, data.size - received)
                if (n < 0) throw MediaFailure("source_changed")
                received += n
            }
            data
        }
    }

    private fun thumbnail(ref: JSONObject): ByteArray {
        val selected = localUri(ref) // no unknown/cloud provider is opened, even for previews
        var bitmap: Bitmap? = null
        try {
            bitmap = if (Build.VERSION.SDK_INT >= 29) {
                activity.contentResolver.loadThumbnail(selected, Size(512, 512), null)
            } else if (ref.getString("kind") == "photo") {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                activity.contentResolver.openInputStream(selected)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                var sample = 1
                while (bounds.outWidth / sample > 512 || bounds.outHeight / sample > 512) sample *= 2
                activity.contentResolver.openInputStream(selected)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
            } else { null }
            var current = bitmap ?: throw MediaFailure("source_unavailable")
            val scale = minOf(1.0, 512.0 / maxOf(current.width, current.height))
            if (scale < 1.0) {
                val small = Bitmap.createScaledBitmap(current, maxOf(1, (current.width * scale).toInt()), maxOf(1, (current.height * scale).toInt()), true)
                current.recycle(); current = small; bitmap = small
            }
            // Encode only pixels into a new JPEG; never copy source EXIF or XMP.
            for (quality in listOf(80, 65, 45, 25, 10)) {
                val out = ByteArrayOutputStream()
                if (current.compress(Bitmap.CompressFormat.JPEG, quality, out) && out.size() <= MAX_THUMBNAIL) return out.toByteArray()
            }
            throw MediaFailure("thumbnail_limit")
        } finally { bitmap?.recycle() }
    }

    private fun refs(): JSONObject {
        registry?.let { return it }
        val loaded = if (registryFile.baseFile.exists()) registryFile.openRead().use { JSONObject(it.bufferedReader().readText()) } else JSONObject()
        registry = loaded; return loaded
    }
    private fun save(refs: JSONObject) {
        val out = registryFile.startWrite()
        try { out.write(refs.toString().toByteArray(Charsets.UTF_8)); registryFile.finishWrite(out) }
        catch (error: Exception) { registryFile.failWrite(out); throw error }
    }
    private fun validHandle(handle: String?): Boolean = try { handle != null && UUID.fromString(handle).toString().equals(handle, true) } catch (_: Exception) { false }
    private class MediaFailure(val reason: String) : Exception()
    private fun reason(error: Exception): String = when (error) {
        is MediaFailure -> error.reason
        is SecurityException -> "permission_denied"
        is java.io.FileNotFoundException -> "source_missing"
        else -> "source_unavailable"
    }
    private fun async(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try { val value = block(); main.post { result.success(value) } }
            catch (error: Exception) { val reason = reason(error); main.post { result.error("MEDIA_UNAVAILABLE", "本机媒体不可用", reason) } }
        }
    }
    private fun finish(value: Any?) { val result = pending; pending = null; pickedUri = null; result?.success(value) }
    private fun finishError(reason: String) { val result = pending; pending = null; pickedUri = null; result?.error("MEDIA_UNAVAILABLE", "本机媒体不可用", reason) }
    fun detach() { channel.setMethodCallHandler(null); finishError("source_unavailable"); worker.shutdown() }
}
