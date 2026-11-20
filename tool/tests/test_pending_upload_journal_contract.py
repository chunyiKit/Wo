"""冻结上传journal静态契约+独立Python/Linux文件模型，不运行Dart/SDK或真实媒体。"""
import copy
import hashlib
import hmac
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOKEN_REF = 'wo.backup.token.' + '1' * 32
KEY_REF = 'wo.backup.recovery.' + '2' * 32
TOKEN = b'b' * 64
KEY = b'B' * 32
CIPHER = bytes(i % 251 for i in range(512))


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()


def identity(family='family', device='device', origin='https://127.0.0.1:9443', pin='f' * 64,
             token=TOKEN, key=KEY, token_ref=TOKEN_REF, key_ref=KEY_REF):
    def proof(domain, ref, value):
        return hashlib.sha256(f'WO-PENDING-UPLOAD/1/{domain}\n{ref}\n'.encode() + value).hexdigest()
    return dict(family_id=family, device_id=device, origin=origin, pin=pin,
                pair_binding=proof('pair', token_ref, token), recovery_binding=proof('recovery', key_ref, key))


def signed(payload, domain, key=KEY):
    tag = hmac.new(key, f'WO-PENDING-UPLOAD/1/{domain}\n'.encode() + canonical(payload), hashlib.sha256).hexdigest()
    return dict(payload, mac=tag)


class JournalOracle:
    """独立格式/恢复模型，不调用Dart实现；真实Dart/native互通仍待运行。"""
    def __init__(self, parent):
        self.parent = parent
        self.slot = parent / 'pending-upload-v1'
        self.used = parent / 'used-backup-ids-v1'
    def manifest(self, backup='backup-one'):
        return dict(version=1, family_id='family', backup_id=backup,
                    entries=[dict(id='opaque', kind='sealed', size=len(CIPHER), sha256=hashlib.sha256(CIPHER).hexdigest())])
    def write(self, path, value):
        with path.open('wb') as file:
            file.write(canonical(value)); file.flush()
            import os
            os.fsync(file.fileno())
    def read_signed(self, path, domain, key=KEY):
        value = json.loads(path.read_bytes())
        tag = value.pop('mac')
        if not hmac.compare_digest(signed(value, domain, key)['mac'], tag): raise ValueError('authentication')
        return value
    def owner(self, expected, key=KEY):
        owner = self.read_signed(self.slot / 'owner.json', 'owner', key)
        if owner['binding'] != expected: raise ValueError('binding')
        return owner
    def freeze(self, binding=None, payload=CIPHER, backup='backup-one'):
        if self.slot.exists(): raise ValueError('pending exists')
        self.used.mkdir(exist_ok=True)
        marker = self.used / hashlib.sha256(f'WO-PENDING-UPLOAD/1/id\n{backup}'.encode()).hexdigest()
        with marker.open('x') as file: file.write('used\n')
        manifest = self.manifest(backup)
        manifest_bytes = json.dumps(manifest, ensure_ascii=False, separators=(',', ':')).encode()
        owner = dict(v=1, binding=binding or identity(), backup_id=backup, manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest())
        metadata = dict(v=1, state='preparing', manifest=manifest, files=['payload-0000'],
                        coverage_notes=['合成记录'], omitted_scopes=[], source_issues={}, allow_public_media=False)
        initial = Path(tempfile.mkdtemp(prefix='pending-init-', dir=self.parent))
        (initial / 'payloads').mkdir()
        self.write(initial / 'owner.json', signed(owner, 'owner'))
        self.write(initial / 'journal.json', signed(metadata, 'journal'))
        initial.rename(self.slot)
        (self.slot / 'payloads' / 'payload-0000').write_bytes(payload)
        if hashlib.sha256(payload).hexdigest() != manifest['entries'][0]['sha256']: raise ValueError('source changed')
        metadata['state'] = 'ready'
        self.write(self.slot / 'journal.next', signed(metadata, 'journal'))
        (self.slot / 'journal.next').replace(self.slot / 'journal.json')
    def resume(self, expected=None, key=KEY):
        if not self.slot.exists(): return None
        owner = self.owner(expected or identity(), key)
        metadata = self.read_signed(self.slot / 'journal.json', 'journal', key)
        if metadata['state'] != 'ready': raise ValueError('not ready')
        raw_manifest = json.dumps(metadata['manifest'], ensure_ascii=False, separators=(',', ':')).encode()
        # canonical sorted JSON与Dart模型toJson顺序不同，重新按固定协议字段排序。
        manifest = metadata['manifest']; entry = manifest['entries'][0]
        protocol = dict(version=manifest['version'], family_id=manifest['family_id'], backup_id=manifest['backup_id'],
                        entries=[dict(id=entry['id'], kind=entry['kind'], size=entry['size'], sha256=entry['sha256'])])
        raw_manifest = json.dumps(protocol, separators=(',', ':')).encode()
        if hashlib.sha256(raw_manifest).hexdigest() != owner['manifest_sha256']: raise ValueError('manifest changed')
        file = self.slot / 'payloads' / 'payload-0000'
        if file.is_symlink() or file.parent.is_symlink() or file.resolve() != file.absolute(): raise ValueError('source path')
        data = file.read_bytes()
        if len(data) != entry['size'] or hashlib.sha256(data).hexdigest() != entry['sha256']: raise ValueError('source changed')
        return metadata, data
    def discard(self, expected=None, key=KEY):
        self.owner(expected or identity(), key)
        shutil.rmtree(self.slot)


class PendingJournalContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / 'lib/local/backup/pending_upload_journal.dart').read_text()
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wo-journal-oracle-')
        self.parent = Path(self.temp.name)
        self.oracle = JournalOracle(self.parent)
    def tearDown(self): self.temp.cleanup()

    def test_api_and_source_only_copy_existing_final_bytes(self):
        for interface in ('class PendingUploadBinding', 'static Future<PendingUploadBinding> current(',
                          'class PendingUploadJob', 'class PendingUploadJournal', 'Future<bool> exists()',
                          'Future<PendingUploadJob> freeze(', 'Future<PendingUploadJob?> resume(',
                          'Future<void> discard(', 'sourceIssues', 'allowPublicMediaOnComputer'):
            self.assertIn(interface, self.source)
        for forbidden in ('SealedBackupSource.create', 'VaultCodec', 'prepareOriginal(', '.seal(', 'HttpClient', 'Socket.connect'):
            self.assertNotIn(forbidden, self.source)
        self.assertIn("entry.kind == 'records'", self.source)
        self.assertIn('source.privacy != BackupPrivacy.restricted', self.source)
        self.assertIn('source.privacy != BackupPrivacy.public || !allowPublicMediaOnComputer', self.source)

    def test_owner_and_preparing_are_published_before_copy_then_ready_is_atomic(self):
        owner = self.source.index("_writeSigned(File('${initial.path}/owner.json')")
        preparing = self.source.index("_writeSigned(File('${initial.path}/journal.json')")
        published = self.source.index('initial.rename(_slot.path)')
        copied = self.source.index('_copySource(sourceMap[')
        ready = self.source.index("journal['state'] = 'ready'")
        self.assertLess(owner, preparing); self.assertLess(preparing, published); self.assertLess(published, copied); self.assertLess(copied, ready)
        self.assertIn("await next.rename('${_slot.path}/journal.json')", self.source)
        self.assertIn('await lock.lock(FileLock.exclusive)', self.source)
        self.assertIn('pending_upload_not_ready', self.source)

    def test_mac_and_native_binding_never_serialize_credentials_or_original_handles(self):
        payload = self.source.split('Map<String, dynamic> toJson()', 1)[1].split('Future<String> _mac(', 1)[0]
        for forbidden in ('token_ref', 'recovery_ref', 'locator', 'bookmark', 'asset_id', "'token'", "'key'"):
            self.assertNotIn(forbidden, payload)
        for guard in ('_proof(_crypto, \'pair\'', '_proof(_crypto, \'recovery\'',
                      '_crypto.hmac(key:', 'pending_upload_authentication_failed', 'backupConstantTimeEquals',
                      'key.fillRange(0, key.length, 0)', 'token.fillRange(0, token.length, 0)'):
            self.assertIn(guard, self.source)
        self.assertEqual(identity()['pair_binding'], 'a9620f61685cd339024ada6c3851934435fe5049ab95c3d75972f4c48b784302')
        self.assertEqual(identity()['recovery_binding'], 'd78ea342479587815d96f5124abcbb8800cdca711552a013a7c14cca9566188a')
        self.assertNotIn(TOKEN_REF.encode(), canonical(identity()))
        self.assertNotIn(TOKEN, canonical(identity()))

    def test_independent_restart_preserves_cipher_manifest_and_no_reencryption(self):
        self.oracle.freeze()
        before = (self.oracle.slot / 'journal.json').read_bytes()
        restarted = JournalOracle(self.parent)
        metadata, cipher = restarted.resume()
        self.assertEqual(cipher, CIPHER)
        self.assertEqual(metadata['manifest']['entries'][0]['sha256'], hashlib.sha256(CIPHER).hexdigest())
        self.assertEqual((self.oracle.slot / 'journal.json').read_bytes(), before)
        self.assertFalse(metadata['allow_public_media'])

    def test_independent_preparing_survives_failure_and_burned_id_cannot_be_recreated(self):
        with self.assertRaisesRegex(ValueError, 'source changed'): self.oracle.freeze(payload=bytes(512))
        self.assertTrue(self.oracle.slot.exists())
        with self.assertRaisesRegex(ValueError, 'not ready'): self.oracle.resume()
        with self.assertRaisesRegex(ValueError, 'binding'): self.oracle.discard(identity(family='other'))
        self.assertTrue(self.oracle.slot.exists())
        self.oracle.discard()
        with self.assertRaises(FileExistsError): self.oracle.freeze()
        self.oracle.freeze(backup='fresh-id')
        self.assertEqual(self.oracle.resume()[0]['manifest']['backup_id'], 'fresh-id')

    def test_independent_scope_and_credential_changes_cannot_resume_or_discard(self):
        self.oracle.freeze()
        changes = [identity(family='other'), identity(device='other'), identity(origin='https://127.0.0.1:9444'),
                   identity(pin='e' * 64), identity(token=b'c' * 64), identity(key=b'C' * 32), identity(key_ref=KEY_REF[:-1] + '3')]
        for expected in changes:
            with self.assertRaises(ValueError): self.oracle.resume(expected)
            with self.assertRaises(ValueError): self.oracle.discard(expected)
            self.assertTrue(self.oracle.slot.exists())
        with self.assertRaisesRegex(ValueError, 'authentication'): self.oracle.resume(key=b'C' * 32)
        self.assertEqual(self.oracle.resume()[1], CIPHER)

    def test_independent_file_and_journal_tamper_are_detected_before_resume(self):
        self.oracle.freeze()
        payload = self.oracle.slot / 'payloads' / 'payload-0000'
        payload.write_bytes(bytes(512))
        with self.assertRaisesRegex(ValueError, 'source changed'): self.oracle.resume()
        payload.write_bytes(CIPHER)
        metadata = self.oracle.slot / 'journal.json'; forged = json.loads(metadata.read_bytes()); forged['allow_public_media'] = True
        metadata.write_bytes(canonical(forged))
        with self.assertRaisesRegex(ValueError, 'authentication'): self.oracle.resume()
        self.assertTrue(self.oracle.slot.exists())
        # 只要owner认证有效，显式discard仍可清除损坏的ready/preparing，不接受别家庭操作。
        self.oracle.discard()

    def test_independent_symlink_is_rejected_and_discard_does_not_delete_target(self):
        self.oracle.freeze()
        target = self.parent / 'outside-source'; target.write_bytes(CIPHER)
        payload = self.oracle.slot / 'payloads' / 'payload-0000'; payload.unlink(); payload.symlink_to(target)
        with self.assertRaisesRegex(ValueError, 'source path'): self.oracle.resume()
        self.oracle.discard(); self.assertEqual(target.read_bytes(), CIPHER)

    def test_limits_native_parent_and_prepared_regressions_are_explicit(self):
        for guard in ('privateParent必须由原生已确认', 'Platform.isWindows', 'private_acl_unavailable',
                      'backupChunkBytes', 'Duration(seconds: 30)', '_maxMetadata = 4 * 1024 * 1024',
                      'pending_upload_id_already_used', 'pending_upload_history_limit', 'followLinks: false'):
            self.assertIn(guard, self.source)
        regressions = (ROOT / 'test/local/backup/pending_upload_journal_test.dart').read_text()
        self.assertEqual(regressions.count("  test('"), 9)
        for scenario in ('跨对象重启续传', 'preparing', '指纹', 'token或恢复钥变化', '链接替换', '受MAC保护清单篡改'):
            self.assertIn(scenario, regressions)

if __name__ == '__main__': unittest.main()
