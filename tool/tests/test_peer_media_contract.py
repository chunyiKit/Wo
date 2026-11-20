"""手机配对/媒体静态安全契约；不运行 Dart、原生桥或 SDK。"""
import base64
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PeerMediaContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.registry = (ROOT / 'lib/local/sync/peer_registry.dart').read_text()
        cls.media = (ROOT / 'lib/local/local_media_repository.dart').read_text()
        cls.regression = (ROOT / 'test/local/sync/registry_media_test.dart').read_text()

    def test_invitation_has_exact_fields_and_strict_parser(self):
        self.assertIn("const fields = {'v', 'link', 'family', 'device', 'secret', 'expires', 'name', 'role'}", self.registry)
        self.assertIn('value.length != fields.length', self.registry)
        self.assertIn('decodeStrictJson(', self.registry)
        self.assertIn('match.end == value.length', self.registry)
        self.assertIn("j['secret_ref'] != 'wo.sync.link.${j['id']}'", self.registry)
        self.assertIn("!value.startsWith('p_') && !value.startsWith('c_')", self.registry)
        self.assertIn('wire64(bytes) != value', self.registry)
        self.assertIn("RegExp(r'^[A-Za-z0-9_-]+$')", self.registry)

    def test_secret_collision_checks_precede_writes(self):
        accept = self.registry.split('Future<PeerLink> accept(', 1)[1].split('Future<PeerLink?> _pending(', 1)[0]
        self.assertLess(accept.index('await _fresh(invitation.linkId)'), accept.index('await crypto.putSecret('))
        fresh = self.registry.split('Future<void> _fresh(', 1)[1].split('Future<bool> _currentAllowed(', 1)[0]
        for guard in ("(await _links()).any((p) => p.id == id)", "sync-invite:$id", "sync-pending-family:$id", "crypto.getSecret('wo.sync.link.$id')"):
            self.assertIn(guard, fresh)
        self.assertIn('existing.fillRange(0, existing.length, 0)', fresh)

    def test_global_queue_covers_security_mutations(self):
        self.assertIn('static Future<void> _tail', self.registry)
        for signature in ('save(PeerLink link)', 'createInvitation(String familyId)',
                          'accept(PairInvitation invitation)', 'lookup(String linkId, String remote)',
                          'authenticated(PeerLink link)', 'scopes(PeerLink link)',
                          'coupleConsent(String linkId, {bool? local, bool? remote})', 'revoke(String id)'):
            self.assertRegex(self.registry, re.escape(signature) + r'\s*=>\s*_serial\(')
        auth = self.registry.split('Future<void> authenticated(', 1)[1].split('Future<Set<String>> scopes(', 1)[0]
        self.assertIn('_same(current, link)', auth)
        self.assertIn('!current.active', auth)
        self.assertIn('await store.batch(changes, privateUpdates:', auth)
        self.assertIn("'sync-invite:${link.id}': null", auth)

    def test_member_mesh_never_grants_unknown_member(self):
        self.assertIn("'local_role': invitation.role", self.registry)
        self.assertIn("else if (invitation.role != 'owner')", self.registry)
        self.assertIn("inviter!['role'] != invitation.role", self.registry)
        self.assertIn("member == null && raw['local_role'] != 'owner'", self.registry)
        self.assertIn("member?['role'] as String? ?? 'member'", self.registry)
        self.assertIn("remote['role'] != link.remoteRole", self.registry)
        self.assertIn("link.remoteRole == 'owner' && await store.privateValue('sync-pending-family:${link.id}') == true", self.registry)

    def test_scope_is_derived_from_current_identity_and_two_consents(self):
        scope = self.registry.split('Future<Set<String>> scopes(', 1)[1].split('Future<void> coupleConsent(', 1)[0]
        self.assertIn('_same(current, link)', scope)
        self.assertIn('!current.active', scope)
        self.assertIn('_currentAllowed(current)', scope)
        self.assertIn('current.coupleLocal && current.coupleRemote', scope)
        self.assertIn('current.familyId', scope)
        self.assertNotIn('_private(', scope)
        self.assertIn("binding['space'] != next.coupleSpace", self.registry)

    def test_complete_jpeg_boundary_replaces_early_sos_return(self):
        parser = self.media.split('static void validateThumbnail(', 1)[1].split('static final _thumbnailQueues', 1)[0]
        self.assertIn('if(marker==217)', parser)
        self.assertIn('pos!=bytes.length', parser)
        self.assertIn('if(next==0)', parser)
        self.assertIn('next>=208&&next<=215', parser)
        self.assertIn('marker>=225&&marker<=239||marker==254', parser)
        self.assertIn('length!=6+2*count', parser)
        self.assertIn('scanning=true;scans++', parser)
        sos = parser.split('}else if(marker==218){', 1)[1]
        self.assertNotIn('return;', sos)

    def test_receive_requires_existing_descriptor_before_repair(self):
        receive = self.media.split('Future<void> receiveThumbnail(', 1)[1].split('Future<BackupSource> prepareBackupSource(', 1)[0]
        self.assertIn('_serializeThumbnail(id', receive)
        for guard in ("scope.startsWith('p_')", 'row==null', "row['thumbnail_sha256']!=digest",
                      "row['thumbnail_bytes']!=bytes.length", "meta['scope']!=scope", "meta['thumbnail_sha256']!=digest"):
            self.assertIn(guard, receive)
        self.assertLess(receive.index("row['thumbnail_sha256']!=digest"), receive.index('repair:true'))
        self.assertIn('Future<void> _saveThumbnailUnlocked(String id,Uint8List bytes,{bool repair=false})', self.media)
        self.assertIn(".corrupt-${const Uuid().v4()}", self.media)
        self.assertIn('if(!repair)throw', self.media)
        self.assertIn('_thumbnailQueues[key]=tail', self.media)

    def test_phone_wire_never_reads_original(self):
        wire = self.media.split('Future<Map<String,dynamic>?> thumbnailForWire(', 1)[1].split('Future<BackupSource> prepareBackupSource(', 1)[0]
        for forbidden in ('native.read(', 'native.prepareOriginal(', "ref['locator']", 'openOriginal(', 'sourceExact'):
            self.assertNotIn(forbidden, wire)
        self.assertIn("scope.startsWith('p_')", wire)
        self.assertIn('thumbnail_sha256', wire)
        backup = self.media.split('Future<BackupSource> prepareBackupSource(', 1)[1]
        self.assertIn('native.prepareOriginal(handle)', backup)
        self.assertIn('_nativeRange(native,handle,0,ready.size)', backup)

    def test_media_order_is_selected_once_and_stable_after_revision_changes(self):
        self.assertIn("'selected_at':DateTime.now().toUtc().toIso8601String()", self.media)
        self.assertIn("final sortKey='${selected}_$mediaId'", self.media)
        self.assertIn("meta['sort_key']!=sortKey", self.media)
        self.assertIn("'sort_key':sortKey", self.media)
        self.assertIn("key(a).compareTo(key(b))", self.media)
        self.assertIn("(a['id'] as String).compareTo(b['id'] as String)", self.media)

    def test_prepared_dart_regressions_use_only_synthetic_jpeg(self):
        match = re.search(r"base64.decode\('([A-Za-z0-9+/=]+)'\)", self.regression)
        self.assertIsNotNone(match)
        raw = base64.b64decode(match.group(1), validate=True)
        self.assertLess(len(raw), 96 * 1024)
        self.assertTrue(raw.startswith(b'\xff\xd8') and raw.endswith(b'\xff\xd9'))
        self.assertNotIn(b'Exif', raw)
        for regression in ('并发消费同一邀请', '跨实例save不丢记录', '后APP1/COM', '坏文件重传修复'):
            self.assertIn(regression, self.regression)


if __name__ == '__main__':
    unittest.main()
