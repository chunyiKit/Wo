"""配对设置的静态权限契约；不执行 Dart、SDK、网络或设备。"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class SyncSettingsContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.page = (ROOT / 'lib/features/profile/local_sync_page.dart').read_text()
        cls.settings = (ROOT / 'lib/features/profile/settings_page.dart').read_text()

    def test_authority_is_explicit_before_create_or_accept(self):
        create = self.page.split('Future<void> _create()', 1)[1].split('Future<void> _accept()', 1)[0]
        accept = self.page.split('Future<void> _accept()', 1)[1].split('Future<void> _couple(', 1)[0]
        self.assertLess(create.index('await _confirm('), create.index('registry.createInvitation('))
        self.assertLess(accept.index('await _confirm('), accept.index('registry.accept('))
        self.assertIn('if (!yes || !mounted) return;', create)
        self.assertIn('if (!yes || !mounted) return;', accept)
        self.assertNotIn('Clipboard', self.page)
        self.assertNotIn('print(', self.page)
        self.assertNotIn('debugPrint(', self.page)

    def test_invitation_is_hidden_on_expiry_background_and_dispose(self):
        self.assertIn('if (_remaining <= 0) _eraseInvitation();', self.page)
        lifecycle = self.page.split('void didChangeAppLifecycleState(', 1)[1].split('Future<void> _load()', 1)[0]
        self.assertIn('_eraseInvitation(); _input.clear();', lifecycle)
        self.assertIn('old.secret.fillRange(0, old.secret.length, 0)', self.page)
        self.assertIn('invitation.secret.fillRange(0, invitation.secret.length, 0)', self.page)
        self.assertIn('_timer?.cancel()', self.page)
        self.assertIn('dispose();', self.page)

    def test_manual_connection_remains_an_authenticated_private_peer_hint(self):
        manual = self.page.split('Future<void> _manual(', 1)[1].split('Widget _peer(', 1)[0]
        self.assertIn('!peer.active', manual)
        self.assertIn('InternetAddress.tryParse', manual)
        self.assertIn('LocalSyncCoordinator.localAddress(ip)', manual)
        self.assertIn('number < 1 || number > 65535', manual)
        self.assertIn('sync.connect(peer, ip.address, number)', manual)
        self.assertNotIn('Socket.connect', manual)
        self.assertIn('MemberAvatar(url:', self.page)
        self.assertIn('coupleConsent(peer.id, local: value)', self.page)
        self.assertNotIn('coupleConsent(peer.id, remote:', self.page)
        self.assertIn('其他配对不会自动被撤销', self.page)

    def test_settings_initializes_backup_only_when_requested_and_catches_safely(self):
        opener = self.settings.split('Future<void> _openBackup(', 1)[1]
        self.assertIn('await runtime.backupController', opener)
        self.assertLess(opener.index('await runtime.backupController'), opener.index('LocalBackupPage(controller: controller)'))
        self.assertIn('if (!context.mounted) return;', opener)
        self.assertIn('catch (_)', opener)
        self.assertNotIn('print(', opener)
        self.assertIn('本机备份模块尚未就绪', opener)

if __name__ == '__main__':
    unittest.main()
