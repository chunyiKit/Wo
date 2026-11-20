"""Dart/Go v2 source contract only; these checks do not execute Dart or native APIs."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ArchiveFileV2Contract(unittest.TestCase):
    def read(self, name):
        return (ROOT / name).read_text()

    def test_outer_and_portable_reader_gate_and_writer_inference(self):
        outer = self.read('lib/local/backup/backup_models.dart')
        inner = self.read('lib/local/backup/portable_archive.dart')
        for source in (outer, inner):
            self.assertIn("this.entries.any((e)=>e.kind=='file')", source)
            self.assertIn("this.version==1", source)
            self.assertIn("version:j['version'] as int", source)
            self.assertIn("'version':version", source)
            self.assertIn("![1,2].contains(j['version'])", source)
            self.assertIn('backupMaxAttachmentBytes', source)
        self.assertIn("sourceExact && kind != 'photo' && kind != 'video'", outer)
        self.assertIn("sourceExact&&kind!='photo'&&kind!='video'", inner)

    def test_binding_index_v2_is_independent_of_v1_coverage(self):
        source = self.read('lib/local/backup/package_binding.dart')
        validate = source.split('static void validate(', 1)[1]
        self.assertIn("![1,2].contains(j['version'])", validate)
        self.assertIn("j['version']==1&&requiredVersion==2", validate)
        self.assertIn("'version':_inventoryVersion(public,restricted)", source)
        coverage = source.split('static List<String> readCoverage(', 1)[1].split('static Object?', 1)[0]
        self.assertIn("j['version']!=1", coverage)
        self.assertNotIn("![1,2].contains(j['version'])", coverage)

    def test_owned_file_remains_private_bounded_and_opaque(self):
        source = self.read('lib/local/media/owned_media_store.dart')
        self.assertIn("static const _kinds={'records','photo','video','thumbnail','file'}", source)
        self.assertIn("kind=='file'&&size>backupMaxAttachmentBytes", source)
        self.assertIn("entry.kind=='file'&&entry.size>backupMaxAttachmentBytes", source)
        self.assertEqual(source.count('BackupPrivacy get privacy=>BackupPrivacy.restricted'), 2)
        self.assertIn("'objects','$id.blob'", source)
        self.assertIn('bool get fullDeviceComplete=>false', source)
        self.assertNotIn('fileName', source)


if __name__ == '__main__':
    unittest.main()
