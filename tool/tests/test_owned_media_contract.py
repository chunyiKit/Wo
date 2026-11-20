"""App私有恢复字节库源码契约；不执行Dart/Flutter/原生/SQLite实现。"""
from pathlib import Path
import re
import unittest
ROOT=Path(__file__).resolve().parents[2]
class OwnedMediaContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source=(ROOT/'lib/local/media/owned_media_store.dart').read_text()
        cls.tests=(ROOT/'test/local/media/owned_media_store_test.dart').read_text()
    def test_target_is_fixed_native_attested_directory(self):
        self.assertIn("privateDirectoryName='owned-media-v1'",self.source)
        self.assertIn('native.privateDirectory(privateDirectoryName)',self.source)
        signature=self.source.split('static Future<OwnedMediaStore> open(',1)[1].split(')async',1)[0]
        self.assertNotIn('Directory',signature)
        self.assertIn('Platform.isWindows',self.source)
    def test_independent_sqlite_never_activates_old_family_or_device(self):
        self.assertIn("p.join(root.path,'owned.sqlite')",self.source)
        self.assertIn('CREATE TABLE owned_assets',self.source)
        self.assertIn('UNIQUE(workspace_id,import_key)',self.source)
        for forbidden in ('LocalStore.open(', "INSERT INTO operations",'newDeviceId','newFamilyId','sourceFamilyId'):
            self.assertNotIn(forbidden,self.source)
        self.assertIn('bool get fullDeviceComplete=>false',self.source)
    def test_portable_manifest_and_mapping_are_required(self):
        section=self.source.split('Future<OwnedMediaAsset> importPortable(',1)[1].split('static Future<void> _source(',1)[0]
        self.assertIn('required PortableRestore restore',section)
        self.assertIn('restore.manifest.entries.where((e)=>e.id==entryId)',section)
        self.assertIn('restore.files[entryId]',section)
        self.assertIn('recovered.entry.toJson()',section)
        self.assertIn('await _source(restore.directory,recovered.file)',section)
        self.assertNotIn('recovered.newId',self.source)
    def test_source_and_target_deny_links_and_traversal(self):
        source=self.source.split('static Future<void> _source(',1)[1].split('Future<FileStat> _verify(',1)[0]
        self.assertIn('followLinks:false',source)
        self.assertIn('p.dirname(resolved)!=parent',source)
        self.assertIn('file.parent.resolveSymbolicLinks()!=parent',source)
        self.assertIn("p.join(_root.path,'objects','$id.blob')",self.source)
        self.assertIn("_owned=RegExp(r'^o_[a-f0-9]{32}$')",self.source)
        self.assertNotIn('.rename(',self.source)
    def test_exclusive_creation_before_write_and_fresh_id_collision_checks(self):
        body=self.source.split('Future<OwnedMediaAsset> importPortable(',1)[1].split('static Future<void> _source(',1)[0]
        self.assertLess(body.index('target.create(exclusive:true)'),body.index('target.open(mode:FileMode.writeOnly)'))
        fresh=self.source.split('Future<String> _freshId()',1)[1].split('Future<OwnedMediaAsset> _reserve(',1)[0]
        self.assertIn("_db.query('owned_assets'",fresh)
        self.assertIn("_db.query('owned_orphans'",fresh)
        self.assertIn('FileSystemEntityType.notFound',fresh)
        self.assertIn('if(id==storeId)continue',fresh)
    def test_copy_hash_and_destination_reverify_before_ready(self):
        body=self.source.split('Future<OwnedMediaAsset> importPortable(',1)[1].split('static Future<void> _source(',1)[0]
        self.assertIn('await for(final chunk in recovered.file.openRead())',body)
        self.assertIn('count!=entry.size||backupHex(hash.finish())!=entry.sha256',body)
        self.assertLess(body.index('await _verify(asset); //'),body.rindex("'status':'ready'"))
        self.assertIn('await output.flush()',body)
    def test_retry_and_every_thumbnail_verify_cannot_skip_jpeg_validation(self):
        verify=self.source.split('Future<FileStat> _verify(',1)[1].split('static bool _sameStat',1)[0]
        self.assertIn("if(asset.kind=='thumbnail')",verify)
        self.assertIn('LocalMediaRepository.validateThumbnail(thumbnail)',verify)
        self.assertIn('thumbnailHash.finish()',verify)
        self.assertIn('invalid_owned_thumbnail',verify)
        self.assertIn("if(asset.available){await _verify(asset);return asset;}",self.source)
        self.assertIn('正确SHA但非法JPEG缩略图失败后重试也不能发布ready',self.tests)
    def test_all_reads_and_thumbnail_relations_are_workspace_scoped(self):
        self.assertIn("where:'workspace_id=? AND id=?'",self.source)
        self.assertIn("where:'workspace_id=? AND import_key=?'",self.source)
        self.assertIn('final asset=await _required(workspaceId,id)',self.source)
        self.assertIn("asset.kind!='thumbnail'||!asset.available",self.source)
        for api in ('verifiedFile(String workspaceId','read(String workspaceId','openRange(String workspaceId','prepareBackupSource(String workspaceId'):
            self.assertIn(api,self.source)
    def test_records_stay_inert_and_source_exact_is_not_promoted(self):
        self.assertIn("_kinds={'records','photo','video','thumbnail','file'}",self.source)
        self.assertIn("entry.kind=='file'&&entry.size>backupMaxAttachmentBytes",self.source)
        self.assertIn('sourceExact:asset.sourceExact',self.source)
        self.assertIn('declaredBytesComplete=>available&&',self.source)
        self.assertIn('声明非exact原件保留字节但不提升保真状态',self.tests)
        self.assertNotIn('jsonDecode(recovered',self.source)
    def test_backup_always_restricted_default_relation_and_bounded_reads(self):
        self.assertEqual(self.source.count('BackupPrivacy get privacy=>BackupPrivacy.restricted'),2)
        self.assertIn('backupId=entryId??asset.originalEntryId',self.source)
        self.assertIn('maxReadBytes=8*1024*1024',self.source)
        self.assertIn('input.read(left>65536?65536:left)',self.source)
        for forbidden in ('NativeMedia(', 'content://', 'photos://', 'ImagePicker(', 'http.Client('):
            self.assertNotIn(forbidden,self.source)
    def test_expected_regressions_are_prepared_not_run(self):
        self.assertEqual(self.tests.count('  test('),13)
        self.assertIn('已准备但未执行Dart/Flutter/SDK',self.tests)
        for scenario in ('新设备无Photos/Files权限','缺原件保留新缩略图引用','源symlink与目标symlink','大合成video流范围','新ID碰撞拒绝','重启持久读取'):
            self.assertIn(scenario,self.tests)
if __name__=='__main__': unittest.main()
