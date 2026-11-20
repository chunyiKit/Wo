"""原生桥静态契约检查；不执行 Dart/Flutter/Android/iOS，不证明原生运行通过。"""
import hashlib
import hmac
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
KOTLIN = ROOT / 'android/app/src/main/kotlin/io/github/chunyikit/wo/WoLocalBridge.kt'
SWIFT = ROOT / 'ios/Runner/WoLocalBridge.swift'
DART = ROOT / 'lib/local/transport/native_local.dart'


class NativeLocalContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.kotlin = KOTLIN.read_text()
        cls.swift = SWIFT.read_text()
        cls.dart = DART.read_text()
        cls.native = (cls.kotlin, cls.swift)

    def test_channel_names_match(self):
        for source in (*self.native, self.dart):
            for channel in ('wo.local/crypto', 'wo.local/discovery', 'wo.local/discovery/events'):
                self.assertIn(channel, source)

    def test_crypto_method_contract_on_both_platforms(self):
        methods = ('random', 'hash', 'hmac', 'seal', 'open',
                   'putSecret', 'getSecret', 'deleteSecret')
        for source in self.native:
            for method in methods:
                self.assertIn('"' + method + '"', source)
        self.assertIn('abstract interface class LocalCrypto', self.dart)
        self.assertIn('implements LocalCrypto', self.dart)
        self.assertIn('Future<Uint8List?> getSecret(String handle)', self.dart)

    def test_same_limits_and_explicit_gcm_tag_format(self):
        for source in self.native:
            self.assertIn('8 * 1024 * 1024', source)
            self.assertIn('4096', source)
            self.assertIn('65536', source)
            self.assertIn('ciphertext ||', source)
        self.assertIn('GCMParameterSpec(128, nonce)', self.kotlin)
        self.assertIn('bytes(call, "key", 32, 32)', self.kotlin)
        self.assertIn('bytes(call, "nonce", 12, 12)', self.kotlin)
        self.assertIn('min: 32, max: 32', self.swift)
        self.assertIn('min: 12, max: 12', self.swift)
        self.assertIn('box.ciphertext + box.tag', self.swift)
        self.assertIn('input.dropLast(16), tag: input.suffix(16)', self.swift)
        self.assertIn('CFBooleanGetTypeID()', self.swift)
        self.assertIn('Int(number.stringValue)', self.swift)
        self.assertIn('Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()', self.kotlin)
        self.assertIn('ciphertext.length - 16', self.dart)
        self.assertIn('plaintext.length + 16', self.dart)

    def test_android_secret_is_device_key_encrypted_and_not_backed_up(self):
        for policy in ('app.noBackupFilesDir', 'AndroidKeyStore', 'setKeySize(256)',
                       'setRandomizedEncryptionRequired(true)', 'AtomicFile',
                       'cipher.updateAAD(handle.toByteArray(Charsets.UTF_8))',
                       'master(false)', 'file.finishWrite(out)', 'file.failWrite(out)'):
            self.assertIn(policy, self.kotlin)
        self.assertNotIn('SharedPreferences', self.kotlin)
        self.assertNotIn('getExternal', self.kotlin)

    def test_ios_secret_never_synchronizes_or_migrates(self):
        self.assertIn('kSecAttrSynchronizable as String: false', self.swift)
        self.assertIn('kSecAttrAccessibleWhenUnlockedThisDeviceOnly', self.swift)
        self.assertIn('SecItemUpdate', self.swift)
        self.assertIn('SecItemCopyMatching', self.swift)
        self.assertIn('SecItemDelete', self.swift)
        self.assertNotIn('UserDefaults', self.swift)
        self.assertNotIn('kSecAttrAccessGroup', self.swift)

    def test_no_secret_logging_or_database(self):
        for source in (*self.native, self.dart):
            self.assertNotRegex(source, r'\b(?:print|debugPrint|NSLog|Log\.[vdiew]|println)\s*\(')
            self.assertNotRegex(source, r'\b(?:sqlite|sqflite|UserDefaults|SharedPreferences)\b')
        # 原生错误消息固定，不将异常、参数、设备详情或 key 回传日志。
        self.assertNotIn('localizedDescription', self.swift)
        self.assertNotIn('exception.message', self.kotlin)

    def test_discovery_schema_and_service_scope(self):
        for source in self.native:
            self.assertIn('_wo-sync._tcp.', source)
            for field in ('event', 'deviceId', 'address', 'port'):
                self.assertIn('"' + field + '"', source)
            self.assertIn('"found"', source)
            self.assertIn('"lost"', source)
            self.assertNotIn('setTxtRecord', source)
            self.assertNotIn('setAttribute(', source)
        self.assertIn('includesPeerToPeer = false', self.swift)
        self.assertIn('NI_NUMERICHOST', self.swift)
        self.assertIn('serviceType.trimEnd', self.kotlin)

    def test_opaque_identifiers_have_matching_allowlist(self):
        pattern = r'^[A-Za-z0-9_-]{16,48}$'
        for source in (*self.native, self.dart):
            self.assertIn(pattern, source)
        self.assertIn('match.end == value.length', self.dart)
        self.assertIn('range.upperBound == value.endIndex', self.swift)
        self.assertIn('range.upperBound == h.endIndex', self.swift)
        compiled = re.compile(pattern)
        for value in ('0123456789abcdef', 'a' * 48, 'A_0-' * 4):
            self.assertRegex(value, compiled)
        for value in ('family/title', 'a' * 49, 'short', '<private>', 'a' * 16 + '\n'):
            self.assertIsNone(compiled.fullmatch(value))

    def test_stopped_discovery_ignores_late_callbacks(self):
        self.assertIn('generation++', self.kotlin)
        self.assertIn('epoch == generation', self.kotlin)
        self.assertIn('present[info.serviceName] == version', self.kotlin)
        self.assertIn('pending.clear(); present.clear(); resolved.clear()', self.kotlin)
        self.assertIn('services[sender.name] === sender', self.swift)
        self.assertIn('browser === self.browser', self.swift)
        self.assertIn('services.removeAll(); resolved.removeAll()', self.swift)
        for source in self.native:
            self.assertIn('fun stop()' if source == self.kotlin else 'func stop()', source)
            self.assertIn('close()', source)

    def test_crypto_work_is_off_main_thread_and_backpressure_is_bounded(self):
        self.assertIn('ArrayBlockingQueue<Runnable>(8)', self.kotlin)
        self.assertIn('worker.execute', self.kotlin)
        self.assertIn('main.post { result.success(value) }', self.kotlin)
        self.assertIn('cryptoQueue.operationCount < 8', self.swift)
        self.assertIn('cryptoQueue.maxConcurrentOperationCount = 1', self.swift)
        self.assertIn('DispatchQueue.main.async { result(value) }', self.swift)

    def test_reference_hash_hmac_vectors_for_platform_acceptance(self):
        # 这里只证明验收文档的公开向量无抄写错误，不调用原生桥。
        self.assertEqual(hashlib.sha256(b'abc').hexdigest(),
                         'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
        self.assertEqual(hmac.new(bytes([11]) * 20, b'Hi There', hashlib.sha256).hexdigest(),
                         'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7')


    def test_private_staging_directory_is_app_scoped_and_fails_closed(self):
        android = (ROOT / "android/app/src/main/kotlin/io/github/chunyikit/wo/WoLocalBridge.kt").read_text()
        ios = (ROOT / "ios/Runner/WoLocalBridge.swift").read_text()
        self.assertIn('val base = app.noBackupFilesDir.canonicalFile', android)
        self.assertLess(android.index('check(directory.canonicalFile == directory.absoluteFile)'), android.index('android.system.Os.chmod(directory.path, 448)'))
        self.assertIn('current.isSymbolicLink != true', ios)
        self.assertIn('FileProtectionType.complete', ios)
        self.assertIn('directory.setResourceValues(flags)', ios)
        self.assertIn('isExcludedFromBackup == true', ios)


if __name__ == '__main__':
    unittest.main()
