import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tool/rebuild' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cp = load('checkpoint')
ai = load('android_install')


class CheckpointTests(unittest.TestCase):
    def repo(self, folder):
        root = Path(folder) / 'repo'; root.mkdir()
        for args in [('init', '-b', 'test-branch'), ('config', 'user.name', 'Test'), ('config', 'user.email', 'test@invalid.local')]:
            subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True)
        (root / 'source.txt').write_text('source')
        subprocess.run(['git', '-C', str(root), 'add', 'source.txt'], check=True)
        subprocess.run(['git', '-C', str(root), 'commit', '-m', 'base'], check=True, capture_output=True)
        return root

    def commit(self, repo, message):
        subprocess.run(['git', '-C', str(repo), 'add', '-A'], check=True)
        subprocess.run(['git', '-C', str(repo), 'commit', '-m', message], check=True, capture_output=True)
        return cp.git(repo, 'rev-parse', 'HEAD').decode().strip()

    def test_bundle_roundtrip_has_exact_commit_and_excludes_untracked_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = self.repo(directory)
            (repo / 'pair.json').write_text(json.dumps({'token': 'private-untracked-value'}))
            out = Path(directory) / 'checkpoint'
            report = cp.checkpoint(repo, out)
            self.assertEqual(report['kind'], 'git_bundle')
            self.assertTrue(report['restored_tree_verified'])
            self.assertFalse(report['untracked_files_included'])
            self.assertFalse(report['cross_failure_domain_saved'])
            self.assertEqual(cp.sha(out / 'source.bundle'), report['sha256'])
            subprocess.run(['git', '-C', str(repo), 'bundle', 'verify', str(out / 'source.bundle')], check=True, capture_output=True)

    def test_sensitive_committed_history_uses_clean_new_module_patch_and_restores_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = self.repo(directory)
            (repo / 'pair.json').write_text('{}')
            base = self.commit(repo, 'historical unsafe file')
            (repo / 'module.txt').write_text('local feature')
            self.commit(repo, 'module')
            out = Path(directory) / 'checkpoint'
            report = cp.checkpoint(repo, out, base=base)
            self.assertEqual(report['kind'], 'format_patch')
            self.assertTrue(report['restored_tree_verified'])
            self.assertEqual(report['requires_base_commit'], base)
            self.assertFalse(report['standalone_history'])
            self.assertNotIn(b'pair.json', (out / 'module.patch').read_bytes())

    def test_new_sensitive_commit_refuses_export_and_does_not_emit_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = self.repo(directory)
            base = cp.git(repo, 'rev-parse', 'HEAD').decode().strip()
            key = 'sk-' + 'A' * 32
            (repo / 'settings.txt').write_text('api_key="' + key + '"')
            self.commit(repo, 'unsafe new credential')
            out = Path(directory) / 'checkpoint'
            with self.assertRaises(cp.CheckpointError):
                cp.checkpoint(repo, out, base=base)
            self.assertFalse((out / 'source.bundle').exists())
            self.assertFalse((out / 'module.patch').exists())
            self.assertNotIn(key, (out / 'manifest.json').read_text())

    def test_private_key_and_commit_message_credentials_are_scanned(self):
        data = b'-----BEGIN ' + b'PRIVATE KEY-----\nprivate\n'
        self.assertIn('private_key_material', cp.content_issues(data))
        with tempfile.TemporaryDirectory() as directory:
            repo = self.repo(directory)
            base = cp.git(repo, 'rev-parse', 'HEAD').decode().strip()
            (repo / 'source.txt').write_text('changed')
            self.commit(repo, 'secret ' + 'sk-' + 'A' * 32)
            with self.assertRaises(cp.CheckpointError):
                cp.checkpoint(repo, Path(directory) / 'checkpoint', base=base)

    def test_route_constants_and_public_certificate_are_not_credentials(self):
        self.assertEqual(cp.content_issues(b"changePassword = '/me/settings/change-password';"), [])
        self.assertEqual(cp.content_issues(b'-----BEGIN CERTIFICATE-----\npublic\n'), [])
        for value in ['config/app.local.json', '.env.production', 'pair.json', 'private.key', 'store.sqlite']:
            self.assertTrue(cp.bad_path(value), value)
        self.assertFalse(cp.bad_path('backend/.env.example'))

    def test_checkpoint_cannot_overwrite_or_live_inside_repo(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = self.repo(directory)
            with self.assertRaises(cp.CheckpointError): cp.checkpoint(repo, repo / 'nested')
            out = Path(directory) / 'old'; out.mkdir()
            with self.assertRaises(cp.CheckpointError): cp.checkpoint(repo, out)


class AndroidInstallTests(unittest.TestCase):
    package = 'io.github.chunyikit.wo.rebuild'

    def metadata(self, path):
        return {'app_id': self.package, 'launch_activity': 'io.github.chunyikit.wo.MainActivity',
                'apk_bytes': path.stat().st_size, 'apk_sha256': ai.file_hash(path),
                'signers': [{'dn': 'CN=Test', 'sha256': 'a' * 64}]}

    def device(self, *args):
        values = list(args)
        if values == ['adb', 'devices']: return 'List of devices attached\ntest-serial\tdevice\n'
        if values[3:] == ['shell', 'pm', 'list', 'users']: return 'Users:\n UserInfo{0:Owner:13} running\n UserInfo{10:Work:30}'
        if values[3:6] == ['shell', 'pm', 'list']: return ''
        if values[3] == 'install': return 'Performing Streamed Install\nSuccess\n'
        if values[3] == 'shell' and values[4].startswith('am start '): return 'Status: ok'
        raise AssertionError(values)

    def test_inspection_records_actual_app_id_and_signer_fingerprint(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'sample.apk'; apk.write_bytes(b'apk')
            badging = f"package: name='{self.package}' versionCode='1'\nlaunchable-activity: name='io.github.chunyikit.wo.MainActivity'\n"
            certificates = 'Signer #1 certificate DN: CN=Test\nSigner #1 certificate SHA-256 digest: ' + 'a' * 64 + '\n'
            with patch.object(ai, 'run', side_effect=[badging, certificates]):
                result = ai.inspect_apk(apk, 'aapt', 'apksigner')
            self.assertEqual(result['app_id'], self.package)
            self.assertEqual(result['signers'][0]['sha256'], 'a' * 64)
            self.assertEqual(result['apk_sha256'], ai.file_hash(apk))

    def test_existing_package_or_retained_data_in_other_user_refuses_without_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'test.apk'; apk.write_bytes(b'apk')
            calls = []
            def run(args, **kwargs):
                calls.append(args)
                if '--user' in args and args[args.index('--user') + 1] == '10': return 'package:' + self.package + '\n'
                return self.device(*args)
            with patch.object(ai, 'inspect_apk', return_value=self.metadata(apk)), patch.object(ai, 'run', side_effect=run):
                with self.assertRaises(ai.SafetyError): ai.install(apk, 'adb', 'aapt', 'signer', 'test-serial', True)
            self.assertFalse(any('install' in args for args in calls))
            self.assertFalse(any('uninstall' in args or 'clear' in args for args in calls))

    def test_absent_isolated_package_installs_without_replace_or_grant_or_clear(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'test.apk'; apk.write_bytes(b'apk')
            calls = []
            def run(args, **kwargs): calls.append(args); return self.device(*args)
            with patch.object(ai, 'inspect_apk', return_value=self.metadata(apk)), patch.object(ai, 'run', side_effect=run):
                result = ai.install(apk, 'adb', 'aapt', 'signer', 'test-serial', True, launch=True)
            self.assertTrue(result['launched'])
            self.assertEqual(result['checked_android_user_count'], 2)
            installs = [args for args in calls if 'install' in args]
            self.assertEqual(len(installs), 1)
            self.assertEqual(installs[0][3:5], ['install', '--no-incremental'])
            self.assertFalse(any(value in args for value in ['uninstall', 'clear', '-r', '-g', '-d'] for args in calls))

    def test_no_explicit_device_confirmation_never_contacts_adb(self):
        with patch.object(ai, 'run') as run:
            with self.assertRaises(ai.SafetyError): ai.guard_device('adb', 'test-serial', False)
            with self.assertRaises(ai.SafetyError): ai.guard_device('adb', '-s', True)
            run.assert_not_called()

    def test_production_package_or_wrong_package_is_rejected_before_device_contact(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'test.apk'; apk.write_bytes(b'apk')
            metadata = {**self.metadata(apk), 'app_id': 'io.github.chunyikit.wo'}
            with patch.object(ai, 'inspect_apk', return_value=metadata), patch.object(ai, 'run') as run:
                with self.assertRaises(ai.SafetyError): ai.install(apk, 'adb', 'aapt', 'signer', 'test-serial', True)
                with self.assertRaises(ai.SafetyError): ai.install(apk, 'adb', 'aapt', 'signer', 'test-serial', True, expected_package='io.github.chunyikit.wo')
                run.assert_not_called()

    def test_unreadable_user_inventory_or_unknown_certificate_fails_closed(self):
        with patch.object(ai, 'adb_call', return_value='unsupported'):
            with self.assertRaises(ai.SafetyError): ai.require_package_absent('adb', 'test-serial', self.package)
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'test.apk'; apk.write_bytes(b'apk')
            with patch.object(ai, 'run', side_effect=[f"package: name='{self.package}'", 'certificate unavailable']):
                with self.assertRaises(ai.SafetyError): ai.inspect_apk(apk, 'aapt', 'signer')


if __name__ == '__main__':
    unittest.main()
