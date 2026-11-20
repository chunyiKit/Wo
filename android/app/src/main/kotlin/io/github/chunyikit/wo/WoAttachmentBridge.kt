package io.github.chunyikit.wo

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/** Explicit ordinary SEND COPIES. No memory/owned handle, URI, or bookmark API. */
class WoAttachmentBridge private constructor(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    companion object {
        private const val REQUEST = 58231
        private const val LIMIT = 20 * 1024 * 1024
        private const val CHUNK = 256 * 1024
        private const val TTL = 15 * 60 * 1000L
        private val PURPOSES = setOf("chat_image_copy", "chat_file_copy", "pet_image_copy", "pet_file_copy")
        private val TOKEN = Regex("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}")
        private val VIDEO_EXT = setOf("mp4", "m4v", "mov", "qt", "avi", "webm", "mkv", "3gp", "3g2", "ts", "mts", "m2ts", "mpg", "mpeg", "mpe", "wmv", "flv", "vob", "ogv", "mxf")
        private val IMAGE_EXT = setOf("jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "ico", "svg", "psd", "jxl", "jp2")
        fun attach(activity: Activity, messenger: BinaryMessenger) = WoAttachmentBridge(activity, messenger)
    }
    private class AttachmentFailure(val reason: String) : Exception()
    private data class Entry(val token: String, val file: File, val name: String, val mime: String, val size: Long, val purpose: String, val expires: Long, var claimed: Boolean = false) {
        fun metadata(): Map<String, Any> = mapOf("token" to token, "displayName" to name, "contentType" to mime, "size" to size, "purpose" to purpose, "kind" to if (purpose.endsWith("image_copy")) "image" else "file")
    }
    private val channel = MethodChannel(messenger, "wo.local/attachments")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val entries = mutableMapOf<String, Entry>() // only worker; never persisted or synchronized
    @Volatile private var closed = false
    private var pending: MethodChannel.Result? = null
    private var purpose = ""
    init { channel.setMethodCallHandler(this); worker.execute { try { root().listFiles()?.filter { it.name.matches(Regex("[a-f0-9-]{36}\\.(copy|partial)")) }?.forEach { if (it.isFile && it.canonicalFile == it.absoluteFile) it.delete() } } catch (_: Exception) {} } }
    private fun root(): File {
        val parent = activity.noBackupFilesDir.canonicalFile
        val root = File(parent, "wo-ordinary-attachments-v1")
        require(root.canonicalFile == root.absoluteFile)
        if (!root.exists()) check(root.mkdir())
        check(root.isDirectory && root.canonicalFile.parentFile == parent)
        android.system.Os.chmod(root.path, 448)
        return root
    }
    private fun expire() { val now = SystemClock.elapsedRealtime(); entries.values.filter { now >= it.expires }.toList().forEach { entries.remove(it.token); it.file.delete() } }
    private fun token(call: MethodCall): String {
        val token = call.argument<String>("token") ?: throw AttachmentFailure("invalid_token")
        if (!TOKEN.matches(token)) throw AttachmentFailure("invalid_token")
        return token
    }
    private fun number(call: MethodCall, key: String): Long {
        val value = call.argument<Number>(key) ?: throw AttachmentFailure("invalid_range")
        val integer = value.toLong()
        if (value.toDouble() != integer.toDouble()) throw AttachmentFailure("invalid_range")
        return integer
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (closed) { result.error("ATTACHMENT_UNAVAILABLE", "附件选择不可用", "closed"); return }
        if (call.method == "pick") {
            val selected = call.argument<String>("purpose")
            if (selected == null || selected !in PURPOSES) { result.error("ATTACHMENT_UNAVAILABLE", "附件用途无效", "invalid_purpose"); return }
            if (pending != null) { result.error("ATTACHMENT_UNAVAILABLE", "请完成当前附件选择", "busy"); return }
            purpose = selected!!; pending = result
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = if (purpose.endsWith("image_copy")) "image/*" else "*/*"
                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            try { activity.startActivityForResult(intent, REQUEST) } catch (_: Exception) { pending = null; result.error("ATTACHMENT_UNAVAILABLE", "无法打开附件选择", "unsupported") }
            return
        }
        if (call.method !in setOf("claim", "read", "release")) { result.notImplemented(); return }
        async(result) {
            expire(); val id = token(call)
            if (call.method == "release") { entries.remove(id)?.file?.delete(); return@async null }
            val entry = entries[id] ?: throw AttachmentFailure("token_expired")
            if (call.method == "claim") {
                if (entry.claimed || call.argument<String>("purpose") != entry.purpose) throw AttachmentFailure("claim_rejected")
                entry.claimed = true; return@async entry.metadata()
            }
            if (!entry.claimed) throw AttachmentFailure("claim_required")
            val offset = number(call, "offset"); val count = number(call, "maxBytes")
            if (offset < 0 || offset > entry.size || count < 1 || count > CHUNK) throw AttachmentFailure("invalid_range")
            if (!entry.file.isFile || entry.file.canonicalFile != entry.file.absoluteFile || entry.file.parentFile != root() || entry.file.length() != entry.size) throw AttachmentFailure("copy_unavailable")
            val bytes = ByteArray(min(count, entry.size - offset).toInt())
            RandomAccessFile(entry.file, "r").use { it.seek(offset); it.readFully(bytes) }
            bytes
        }
    }
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        val callback = pending ?: return true; pending = null
        if (resultCode != Activity.RESULT_OK) { callback.success(null); return true }
        val uri = data?.data
        if (uri == null || uri.scheme != "content" || data?.clipData?.itemCount?.let { it != 1 } == true) { callback.error("ATTACHMENT_UNAVAILABLE", "附件选择无效", "unsupported"); return true }
        val selectedPurpose = purpose
        async(callback) { copySelection(uri, selectedPurpose) }
        return true
    }
    private fun safeName(value: String): String {
        val leaf = value.replace('\\', '/').substringAfterLast('/').replace(Regex("[^A-Za-z0-9._ -]"), "_").trim().trimStart('.')
        return leaf.take(100).ifBlank { "attachment.bin" }
    }
    private fun mime(value: String?): String = value?.lowercase()?.takeIf { it.length <= 100 && Regex("[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+").matches(it) } ?: "application/octet-stream"
    private fun copySelection(uri: Uri, purpose: String): Map<String, Any> {
        expire(); if (entries.size >= 4) throw AttachmentFailure("selection_limit"); val token = UUID.randomUUID().toString(); val dir = root()
        val partial = File(dir, "$token.partial"); val target = File(dir, "$token.copy")
        if (entries.containsKey(token)) throw AttachmentFailure("token_collision")
        var partialOwned = false; var targetOwned = false
        var display = "attachment.bin"; var declared: Long? = null
        activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) { val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME); if (n >= 0 && !c.isNull(n)) display = safeName(c.getString(n)); val z = c.getColumnIndex(OpenableColumns.SIZE); if (z >= 0 && !c.isNull(z)) declared = c.getLong(z) }
        }
        if (declared != null && (declared!! < 1 || declared!! > LIMIT)) throw AttachmentFailure("size_limit")
        val type = mime(activity.contentResolver.getType(uri)); val ext = display.substringAfterLast('.', "").lowercase()
        if (type.startsWith("video/") || ext in VIDEO_EXT) throw AttachmentFailure("video_unsupported")
        try {
            if (!partial.createNewFile()) throw AttachmentFailure("copy_unavailable")
            partialOwned = true
            var total = 0L
            activity.contentResolver.openInputStream(uri)?.use { input -> FileOutputStream(partial).use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) { if (closed || Thread.currentThread().isInterrupted) throw AttachmentFailure("closed"); val n = input.read(buffer); if (n < 0) break; if (n == 0) continue; total += n; if (total > LIMIT) throw AttachmentFailure("size_limit"); output.write(buffer, 0, n) }; output.fd.sync()
            } } ?: throw AttachmentFailure("copy_unavailable")
            if (total < 1) throw AttachmentFailure("empty_file")
            val header = RandomAccessFile(partial, "r").use { val b = ByteArray(min(512L, total).toInt()); it.readFully(b); b }
            if (videoMagic(header)) throw AttachmentFailure("video_unsupported")
            val isImageCopy = purpose.endsWith("image_copy")
            var outType = type
            if (isImageCopy) {
                val bytes = imageCopy(partial)
                if (bytes.isEmpty() || bytes.size > LIMIT) throw AttachmentFailure("size_limit")
                if (!target.createNewFile()) throw AttachmentFailure("copy_unavailable")
                targetOwned = true
                FileOutputStream(target).use { it.write(bytes); it.fd.sync() }
                display = safeName(display.substringBeforeLast('.', display) + ".jpg"); outType = "image/jpeg"
            } else {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }; BitmapFactory.decodeFile(partial.path, bounds)
                if (type.startsWith("image/") || ext in IMAGE_EXT || bounds.outWidth > 0 || imageMagic(header)) throw AttachmentFailure("image_requires_copy")
                // Same private filesystem: link creates exclusively, unlike renameTo.
                // Only our copied bytes are linked; the user source is never linked.
                android.system.Os.link(partial.path, target.path)
                targetOwned = true
                if (!partial.delete()) throw AttachmentFailure("copy_unavailable")
                partialOwned = false
            }
            if (closed) throw AttachmentFailure("closed")
            val entry = Entry(token, target, display, outType, target.length(), purpose, SystemClock.elapsedRealtime() + TTL)
            entries[token] = entry; return entry.metadata()
        } catch (error: Exception) { if (targetOwned) target.delete(); throw error } finally { if (partialOwned) partial.delete() }
    }
    private fun videoMagic(b: ByteArray): Boolean {
        fun at(n: Int, s: String) = n >= 0 && b.size >= n + s.length && s.indices.all { (b[n + it].toInt() and 255) == s[it].code }
        if (at(4, "ftyp")) { val brand = if (b.size >= 12) String(b, 8, 4, Charsets.US_ASCII) else ""; return brand !in setOf("heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis") }
        val unsigned = b.map { it.toInt() and 255 }
        val asf = listOf(0x30,0x26,0xb2,0x75,0x8e,0x66,0xcf,0x11,0xa6,0xd9,0,0xaa,0,0x62,0xce,0x6c)
        if (unsigned.take(asf.size) == asf || unsigned.take(4) == listOf(6,14,43,52) || b.size > 376 && listOf(0,188,376).all { unsigned[it] == 0x47 } || b.size > 388 && listOf(4,196,388).all { unsigned[it] == 0x47 }) return true
        return at(0, "FLV") || at(0, "OggS") || at(0, "RIFF") && at(8, "AVI ") || b.size >= 4 && ((b[0].toInt() and 255) == 0x1a && (b[1].toInt() and 255) == 0x45 && (b[2].toInt() and 255) == 0xdf && (b[3].toInt() and 255) == 0xa3 || b[0] == 0.toByte() && b[1] == 0.toByte() && b[2] == 1.toByte() && (b[3].toInt() and 255) in setOf(0xba, 0xb3))
    }
    private fun imageMagic(b: ByteArray): Boolean {
        val ascii = String(b, Charsets.ISO_8859_1); val text = ascii.trimStart().lowercase()
        val prefix = b.map { it.toInt() and 255 }
        if (prefix.take(4) in listOf(listOf(0,0,1,0),listOf(0,0,2,0),listOf(0xff,0x4f,0xff,0x51)) || prefix.take(2) == listOf(0xff,0x0a) || ascii.startsWith("P") && ascii.length > 2 && ascii[1] in '1'..'7' && ascii[2].isWhitespace()) return true
        return b.size >= 2 && ((b[0].toInt() and 255) == 0xff && (b[1].toInt() and 255) == 0xd8 || ascii.startsWith("BM") || ascii.startsWith("II") || ascii.startsWith("MM")) || ascii.startsWith("\u0089PNG") || ascii.startsWith("GIF8") || ascii.startsWith("8BPS") || ascii.startsWith("RIFF") && ascii.drop(8).startsWith("WEBP") || ascii.drop(4).startsWith("ftyp") || text.startsWith("<svg") || text.startsWith("<?xml") && text.contains("<svg")
    }
    private fun imageCopy(source: File): ByteArray {
        val bitmap: Bitmap
        if (Build.VERSION.SDK_INT >= 28) {
            bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(source)) { decoder, info, _ ->
                if (info.size.width < 1 || info.size.height < 1 || info.size.width.toLong() * info.size.height > 100_000_000L) throw AttachmentFailure("image_invalid")
                val scale = min(1.0, 1600.0 / max(info.size.width, info.size.height)); decoder.setTargetSize(max(1, (info.size.width * scale).toInt()), max(1, (info.size.height * scale).toInt()))
                decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB)); decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } else {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }; BitmapFactory.decodeFile(source.path, options)
            if (options.outWidth < 1 || options.outHeight < 1 || options.outWidth.toLong() * options.outHeight > 100_000_000L) throw AttachmentFailure("image_invalid")
            var sample = 1; while (max(options.outWidth, options.outHeight) / sample > 3200) sample *= 2
            options.inJustDecodeBounds = false; options.inSampleSize = sample; options.inPreferredConfig = Bitmap.Config.ARGB_8888
            if (Build.VERSION.SDK_INT >= 26) options.inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
            val decoded = BitmapFactory.decodeFile(source.path, options) ?: throw AttachmentFailure("image_invalid")
            val orientation = try { ExifInterface(source.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) } catch (_: Exception) { 1 }
            val matrix = Matrix().apply { when (orientation) { 2 -> setScale(-1f, 1f); 3 -> setRotate(180f); 4 -> setScale(1f, -1f); 5 -> { setRotate(90f); postScale(-1f, 1f) }; 6 -> setRotate(90f); 7 -> { setRotate(270f); postScale(-1f, 1f) }; 8 -> setRotate(270f) } }
            bitmap = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true); if (bitmap !== decoded) decoded.recycle()
        }
        try {
            val scale = min(1.0, 1600.0 / max(bitmap.width, bitmap.height)); val w = max(1, (bitmap.width * scale).toInt()); val h = max(1, (bitmap.height * scale).toInt())
            val clean = if (Build.VERSION.SDK_INT >= 26) Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888, false, ColorSpace.get(ColorSpace.Named.SRGB)) else Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            try { val canvas = Canvas(clean); canvas.drawColor(android.graphics.Color.BLACK); canvas.drawBitmap(bitmap, null, android.graphics.Rect(0, 0, w, h), Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)); val out = ByteArrayOutputStream(); if (!clean.compress(Bitmap.CompressFormat.JPEG, 88, out)) throw AttachmentFailure("image_invalid"); return stripAttachmentMetadata(out.toByteArray()) } finally { clean.recycle() }
        } finally { bitmap.recycle() }
    }
    private fun stripAttachmentMetadata(encoded: ByteArray): ByteArray {
        fun value(index: Int) = encoded[index].toInt() and 0xff
        fun invalid(): Nothing = throw AttachmentFailure("image_invalid")
        if (encoded.size < 4 || value(0) != 0xff || value(1) != 0xd8) invalid()
        val out = ByteArrayOutputStream(encoded.size)
        out.write(encoded, 0, 2)
        var position = 2
        var inScan = false
        var sawScan = false
        while (position < encoded.size) {
            if (inScan) {
                val entropyStart = position
                var foundMarker = false
                while (position < encoded.size) {
                    if (value(position) != 0xff) { position++; continue }
                    val markerStart = position
                    var next = position + 1
                    while (next < encoded.size && value(next) == 0xff) next++
                    if (next >= encoded.size) invalid()
                    val marker = value(next)
                    if (marker == 0x00 || marker == 0x01 || marker in 0xd0..0xd7) { position = next + 1; continue }
                    out.write(encoded, entropyStart, markerStart - entropyStart)
                    position = markerStart
                    inScan = false
                    foundMarker = true
                    break
                }
                if (!foundMarker) invalid() // no EOI: do not return truncated entropy
                continue
            }
            val markerStart = position
            if (value(position) != 0xff) invalid()
            while (position < encoded.size && value(position) == 0xff) position++
            if (position >= encoded.size) invalid()
            val marker = value(position++)
            if (marker == 0xd9) {
                if (!sawScan || position != encoded.size) invalid()
                out.write(encoded, markerStart, position - markerStart)
                return out.toByteArray()
            }
            if (marker == 0x00 || marker == 0xd8 || marker in 0xd0..0xd7) invalid()
            if (marker == 0x01) { out.write(encoded, markerStart, position - markerStart); continue }
            if (encoded.size - position < 2) invalid()
            val length = (value(position) shl 8) or value(position + 1)
            if (length < 2 || length > encoded.size - position) invalid()
            val end = position + length
            // Fresh encoder output only: remove all APP0..15 and COM.
            if (marker !in 0xe0..0xef && marker != 0xfe) out.write(encoded, markerStart, end - markerStart)
            position = end
            if (marker == 0xda) { inScan = true; sawScan = true }
        }
        invalid()
    }
    private fun async(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute { try { if (closed) throw AttachmentFailure("closed"); val value = block(); main.post { result.success(value) } } catch (error: Exception) { val reason = (error as? AttachmentFailure)?.reason ?: if (error is SecurityException) "permission_denied" else "copy_unavailable"; main.post { result.error("ATTACHMENT_UNAVAILABLE", "普通附件副本不可用", reason) } } }
    }
    fun close() {
        if (closed) return
        closed = true; channel.setMethodCallHandler(null); pending?.error("ATTACHMENT_UNAVAILABLE", "附件选择已中断", "closed"); pending = null
        worker.execute { entries.values.forEach { it.file.delete() }; entries.clear() }; worker.shutdown()
    }
}
