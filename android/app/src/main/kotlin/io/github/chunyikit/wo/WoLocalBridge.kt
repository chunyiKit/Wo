package io.github.chunyikit.wo

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.ArrayDeque
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** 仅提供设备本地原语。NSD 数据不代表已鉴权的成员或家庭。 */
class WoLocalBridge(context: Context, messenger: BinaryMessenger) : AutoCloseable {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val crypto = MethodChannel(messenger, "wo.local/crypto")
    private val discovery = MethodChannel(messenger, "wo.local/discovery")
    private val events = EventChannel(messenger, "wo.local/discovery/events")
    private val worker = ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS,
        ArrayBlockingQueue<Runnable>(8))
    private val random = SecureRandom()
    private val nsd = app.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var sink: EventChannel.EventSink? = null
    private var closed = false
    private var generation = 0L
    private var ownId: String? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var browser: NsdManager.DiscoveryListener? = null
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private val present = mutableMapOf<String, Long>()
    private val resolved = mutableMapOf<String, Map<String, Any>>()
    private var serial = 0L

    companion object {
        private const val MAX_BYTES = 8 * 1024 * 1024
        private const val SERVICE_TYPE = "_wo-sync._tcp."
        private const val ALIAS = "wo.local.registry.v1"
        private val OPAQUE = Regex("^[A-Za-z0-9_-]{16,48}$")
        private val HANDLE = Regex("^[A-Za-z0-9_.-]{1,100}$")
    }

    init {
        crypto.setMethodCallHandler { call, result ->
            if (closed) result.error("closed", "Local bridge is closed", null)
            else try {
                worker.execute {
                    try {
                        val value = cryptoCall(call)
                        main.post { result.success(value) }
                    } catch (_: IllegalArgumentException) {
                        main.post { result.error("invalid_argument", "Invalid crypto input", null) }
                    } catch (_: Exception) {
                        main.post { result.error("crypto_failed", "Local crypto operation failed", null) }
                    } finally {
                        // 最佳努力清理本桥持有的瞬时参数；不保证 Dart/codec 的额外拷贝已清除。
                        (call.arguments as? Map<*, *>)?.let { args ->
                            (args["key"] as? ByteArray)?.fill(0)
                            if (call.method == "putSecret") (args["bytes"] as? ByteArray)?.fill(0)
                        }
                    }
                }
            } catch (_: java.util.concurrent.RejectedExecutionException) {
                result.error("busy", "Local crypto queue is full", null)
            }
        }
        discovery.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        require(!closed)
                        val id = call.argument<String>("serviceName") ?: error("missing id")
                        val port = integer(call, "port")
                        require(OPAQUE.matches(id) && port in 1..65535)
                        start(id, port)
                        result.success(null)
                    }
                    "stop" -> { stop(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                stop()
                result.error("discovery_failed", "Local discovery operation failed", null)
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) { sink = eventSink }
            override fun onCancel(arguments: Any?) { sink = null; stop() }
        })
    }

    private fun integer(call: MethodCall, name: String): Int {
        val value = (call.arguments as? Map<*, *>)?.get(name)
        return when (value) {
            is Int -> value
            is Long -> { require(value in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()); value.toInt() }
            else -> throw IllegalArgumentException()
        }
    }
    private fun bytes(call: MethodCall, name: String, min: Int = 0, max: Int = MAX_BYTES): ByteArray {
        val value = call.argument<ByteArray>(name) ?: throw IllegalArgumentException()
        require(value.size in min..max)
        return value
    }
    private fun handle(call: MethodCall): String {
        val value = call.argument<String>("handle") ?: throw IllegalArgumentException()
        require(HANDLE.matches(value))
        return value
    }
    private fun cryptoCall(call: MethodCall): Any? = when (call.method) {
        "random" -> {
            val count = integer(call, "count")
            require(count in 1..64)
            ByteArray(count).also { random.nextBytes(it) }
        }
        "hash" -> MessageDigest.getInstance("SHA-256").digest(bytes(call, "bytes"))
        "hmac" -> Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(bytes(call, "key", 1, 4096), "HmacSHA256"))
            doFinal(bytes(call, "data"))
        }
        "seal", "open" -> {
            val key = bytes(call, "key", 32, 32)
            val nonce = bytes(call, "nonce", 12, 12)
            val aad = bytes(call, "aad", 0, 65536)
            val seal = call.method == "seal"
            val input = if (seal) bytes(call, "plaintext") else bytes(call, "ciphertext", 16, MAX_BYTES + 16)
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(if (seal) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE,
                    SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
                updateAAD(aad)
                doFinal(input) // ciphertext || 16-byte tag, never nonce-prefixed
            }
        }
        "putSecret" -> { putSecret(handle(call), bytes(call, "bytes", 0, 4096)); null }
        "getSecret" -> getSecret(handle(call))
        "deleteSecret" -> {
            val file = secretFile(handle(call))
            file.delete()
            check(!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists())
            null
        }
        else -> throw IllegalArgumentException()
    }

    private fun secretFile(handle: String): AtomicFile {
        val dir = File(app.noBackupFilesDir, "wo-local-secrets-v1")
        check(dir.isDirectory || dir.mkdirs())
        val name = MessageDigest.getInstance("SHA-256").digest(handle.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        return AtomicFile(File(dir, name))
    }
    private fun master(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        check(create) // 已存在密文却丢失设备密钥时拒绝，绝不返回空 secret。
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
            generateKey()
        }
    }
    private fun putSecret(handle: String, value: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, master(true)) // Keystore 自行生成随机 nonce。
        cipher.updateAAD(handle.toByteArray(Charsets.UTF_8))
        val encrypted = cipher.doFinal(value)
        check(cipher.iv.size == 12)
        val file = secretFile(handle)
        val out = file.startWrite()
        try {
            out.write(byteArrayOf(1)); out.write(cipher.iv); out.write(encrypted)
            file.finishWrite(out)
        } catch (e: Exception) { file.failWrite(out); throw e }
    }
    private fun getSecret(handle: String): ByteArray? {
        val file = secretFile(handle)
        val raw = try {
            file.openRead().use { input ->
                val b = input.readBytesLimited(4126)
                require(b.size in 29..4125 && b[0].toInt() == 1)
                b
            }
        } catch (e: java.io.FileNotFoundException) {
            if (file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()) throw e
            return null
        }
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, master(false), GCMParameterSpec(128, raw.copyOfRange(1, 13)))
            updateAAD(handle.toByteArray(Charsets.UTF_8))
            doFinal(raw.copyOfRange(13, raw.size))
        }
    }
    private fun java.io.InputStream.readBytesLimited(limit: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(1024)
        while (out.size() < limit) {
            val n = read(buf, 0, minOf(buf.size, limit - out.size()))
            if (n < 0) break
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    private fun fail(epoch: Long) {
        if (epoch == generation && ownId != null) {
            sink?.error("discovery_failed", "Local network discovery unavailable", null)
            stop()
        }
    }
    @Suppress("DEPRECATION") // API16 resolveService 保持最低系统兼容；每次连接仍须重新鉴权。
    private fun start(id: String, port: Int) {
        stop()
        val epoch = generation
        ownId = id
        val registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) { main.post {
                if (epoch != generation || info.serviceName != id) {
                    try { nsd.unregisterService(this) } catch (_: Exception) {}
                    if (epoch == generation) fail(epoch)
                }
            } }
            override fun onRegistrationFailed(info: NsdServiceInfo, error: Int) { main.post { fail(epoch) } }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, error: Int) { main.post {
                if (epoch == generation) sink?.error("discovery_stop_failed", "Local advertisement stop failed", null)
            } }
        }
        registration = registrationListener
        nsd.registerService(NsdServiceInfo().apply { serviceName = id; serviceType = SERVICE_TYPE; setPort(port) },
            NsdManager.PROTOCOL_DNS_SD, registrationListener)
        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) { main.post {
                if (epoch != generation) try { nsd.stopServiceDiscovery(this) } catch (_: Exception) {}
            } }
            override fun onStartDiscoveryFailed(type: String, error: Int) { main.post { fail(epoch) } }
            override fun onStopDiscoveryFailed(type: String, error: Int) { main.post {
                if (epoch == generation) sink?.error("discovery_stop_failed", "Local browse stop failed", null)
            } }
            override fun onDiscoveryStopped(type: String) {}
            override fun onServiceFound(info: NsdServiceInfo) { main.post {
                if (epoch == generation && info.serviceType.trimEnd('.') == SERVICE_TYPE.trimEnd('.') &&
                    info.serviceName != id && OPAQUE.matches(info.serviceName) && present.size < 128) {
                    present[info.serviceName] = ++serial
                    if (pending.size < 128) pending.add(info)
                    resolveNext(epoch)
                }
            } }
            override fun onServiceLost(info: NsdServiceInfo) { main.post {
                if (epoch == generation) {
                    present.remove(info.serviceName)
                    resolved.remove(info.serviceName)?.let { sink?.success(it + ("event" to "lost")) }
                }
            } }
        }
        browser = discoveryListener
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }
    @Suppress("DEPRECATION")
    private fun resolveNext(epoch: Long) {
        if (epoch != generation || resolving || pending.isEmpty()) return
        val info = pending.removeFirst()
        val version = present[info.serviceName]
        if (version == null) { resolveNext(epoch); return }
        resolving = true
        try {
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(service: NsdServiceInfo, error: Int) { main.post {
                    if (epoch == generation) { resolving = false; resolveNext(epoch) }
                } }
                override fun onServiceResolved(service: NsdServiceInfo) { main.post {
                    if (epoch == generation) {
                        resolving = false
                        val address = service.host?.hostAddress
                        if (present[info.serviceName] == version && address != null && service.port in 1..65535) {
                            val value = mapOf<String, Any>("event" to "found", "deviceId" to info.serviceName,
                                "address" to address, "port" to service.port)
                            resolved[info.serviceName] = value
                            sink?.success(value)
                        }
                        resolveNext(epoch)
                    }
                } }
            })
        } catch (_: Exception) { resolving = false; resolveNext(epoch) }
    }
    fun stop() {
        generation++
        ownId = null
        browser?.let { try { nsd.stopServiceDiscovery(it) } catch (_: Exception) {} }
        registration?.let { try { nsd.unregisterService(it) } catch (_: Exception) {} }
        browser = null; registration = null
        pending.clear(); present.clear(); resolved.clear(); resolving = false
    }
    override fun close() {
        closed = true
        stop()
        crypto.setMethodCallHandler(null); discovery.setMethodCallHandler(null); events.setStreamHandler(null)
        sink = null
        worker.shutdownNow()
    }
}
