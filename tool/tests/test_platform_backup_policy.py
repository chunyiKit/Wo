"""只读静态政策检查；不调用 Flutter、Gradle、Xcode、ADB 或网络。"""
from pathlib import Path
import subprocess
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / 'android/app/src/main'
NS = '{http://schemas.android.com/apk/res/android}'
DOMAINS = {'root', 'file', 'database', 'sharedpref', 'external',
           'device_root', 'device_file', 'device_database', 'device_sharedpref'}


class PlatformBackupPolicyTest(unittest.TestCase):
    def test_manifest_explicitly_disables_backup_and_references_both_policies(self):
        app = ET.parse(ANDROID / 'AndroidManifest.xml').getroot().find('application')
        self.assertEqual(app.attrib[NS + 'allowBackup'], 'false')
        self.assertEqual(app.attrib[NS + 'fullBackupContent'], '@xml/wo_backup_rules')
        self.assertEqual(app.attrib[NS + 'dataExtractionRules'], '@xml/wo_data_extraction_rules')

    def assert_complete_exclusion(self, section):
        self.assertFalse(section.findall('include'))
        rows = section.findall('exclude')
        self.assertEqual(len(rows), len(DOMAINS))
        self.assertEqual({r.attrib['domain'] for r in rows}, DOMAINS)
        self.assertTrue(all(r.attrib['path'] == '.' for r in rows))

    def test_legacy_all_app_domains_are_excluded_without_partial_paths(self):
        root = ET.parse(ANDROID / 'res/xml/wo_backup_rules.xml').getroot()
        self.assertEqual(root.tag, 'full-backup-content')
        self.assert_complete_exclusion(root)

    def test_android12_cloud_and_device_transfer_are_separately_excluded(self):
        root = ET.parse(ANDROID / 'res/xml/wo_data_extraction_rules.xml').getroot()
        self.assertEqual(root.tag, 'data-extraction-rules')
        self.assertEqual([c.tag for c in root], ['cloud-backup', 'device-transfer'])
        self.assert_complete_exclusion(root.find('cloud-backup'))
        self.assert_complete_exclusion(root.find('device-transfer'))

    def test_no_android_permissions_added_by_backup_or_test_package_changes(self):
        before = subprocess.run(
            ['git', 'show', 'c4f089bda0b2a0b7789261c669509681bd99f040:android/app/src/main/AndroidManifest.xml'],
            cwd=ROOT, check=True, capture_output=True, text=True,
        ).stdout
        base = ET.fromstring(before)
        current = ET.parse(ANDROID / 'AndroidManifest.xml').getroot()
        def permissions(node):
            return {tuple(sorted(row.attrib.items())) for row in node.findall('uses-permission')}
        self.assertEqual(permissions(base), permissions(current))

    def test_source_has_explicit_test_opt_in_and_unchanged_default_app_id(self):
        # 源码契约，不把这些断言当作实际 Gradle 变体或 APK 验签结果。
        gradle = (ROOT / 'android/app/build.gradle.kts').read_text()
        self.assertIn('environmentVariable("WO_REBUILD_TEST_APP")', gradle)
        self.assertIn('woRebuildTestSetting in setOf("0", "1")', gradle)
        self.assertIn('val woRebuildTestApp = woRebuildTestSetting == "1"', gradle)
        self.assertIn('applicationId = "io.github.chunyikit.wo"', gradle)
        self.assertIn('if (woRebuildTestApp) {\n                applicationIdSuffix = ".rebuild"', gradle)
        self.assertIn('manifestPlaceholders["WO_APP_LABEL"]', gradle)
        app = ET.parse(ANDROID / 'AndroidManifest.xml').getroot().find('application')
        self.assertEqual(app.attrib[NS + 'label'], '${WO_APP_LABEL}')

    def test_ios_only_fixed_app_roots_and_verified_exclusion_result(self):
        swift = (ROOT / 'ios/Runner/AppDelegate.swift').read_text()
        self.assertIn('engineBridge.applicationRegistrar.messenger()', swift)
        self.assertIn('FileManager.SearchPathDirectory.documentDirectory, .libraryDirectory', swift)
        self.assertIn('values.isExcludedFromBackup = true', swift)
        self.assertIn('directory.resourceValues(forKeys: [.isExcludedFromBackupKey])', swift)
        self.assertIn('guard checked.isExcludedFromBackup == true', swift)
        self.assertIn('result(["documents": true, "library": true])', swift)
        self.assertIn('FlutterError(code: "LOCAL_PRIVACY"', swift)
        self.assertNotIn('call.arguments', swift)
        self.assertNotIn('localizedDescription', swift)

    def test_dart_ios_prepare_waits_and_has_no_error_swallow_or_android_permission_request(self):
        dart = (ROOT / 'lib/local/local_privacy.dart').read_text()
        self.assertIn('if (!Platform.isIOS) return;', dart)
        self.assertIn("await channel.invokeMapMethod<String, dynamic>('prepare')", dart)
        self.assertIn("result?['documents'] != true || result?['library'] != true", dart)
        self.assertIn('throw StateError', dart)
        self.assertNotIn('catch', dart)
        self.assertNotIn('requestPermission', dart)


if __name__ == '__main__':
    unittest.main()
