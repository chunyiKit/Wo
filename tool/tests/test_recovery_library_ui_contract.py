"""独立恢复资料库UI源码边界；纯Python，不执行Dart或原生媒体，不等于编译/真机验收。"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class RecoveryLibraryUiContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / 'lib/features/settings/recovery_library_page.dart').read_text()

    def test_page_is_injected_and_never_activates_normal_data_routes(self):
        for signature in ('required this.store', 'this.pendingRestore', 'this.backupControllerFor'):
            self.assertIn(signature, self.source)
        for forbidden in ('LocalRuntime', 'WoScope', 'LocalStore', 'ApiClient', '.merge(', '.patch(', 'setCurrentFamily', 'Navigator.pushNamed', 'context.go(', 'context.push('):
            self.assertNotIn(forbidden, self.source)

    def test_explicit_confirm_and_full_fingerprint_bind_import(self):
        action = self.source.split('Future<void> _import()', 1)[1].split('Future<void> _open(', 1)[0]
        for required in ('var understood=false', 'CheckboxListTile(', 'onPressed:understood?', 'confirmed!=true', 'expectedFingerprint:plan.fingerprint', '_preview?.fingerprint!=plan.fingerprint'):
            self.assertIn(required, action)
        self.assertLess(action.index('confirmed!=true'), action.index('store.importVerified('))
        self.assertIn('SelectableText(plan.fingerprint', action)
        self.assertNotIn('substring(', action)

    def test_preview_does_not_import_without_explicit_action(self):
        preview = self.source.split('Future<void> _loadPreview()', 1)[1].split('Future<void> _import()', 1)[0]
        self.assertIn('await store.preview(restore)', preview)
        self.assertNotIn('importVerified', preview)
        self.assertEqual(self.source.count('store.importVerified('), 1)
        self.assertIn('1=>\'v1 记录没有操作历史或授权证据', self.source)
        self.assertIn('记录来源与历史授权仍未证实', self.source)

    def test_cached_lists_survive_refresh_and_failure(self):
        for declaration in ('List<RecoveryWorkspace>? _items', 'List<RecoveryDocument>? _documents', 'List<OwnedMediaAsset>? _assets'):
            self.assertIn(declaration, self.source)
        refresh = self.source.split('Future<void> _refresh()', 1)[1].split('Future<void> _loadPreview()', 1)[0]
        failure = refresh.split('catch(e)', 1)[1]
        self.assertNotIn('_items=null', failure)
        self.assertIn('_refreshing&&items!=null', self.source)
        self.assertIn('_loading&&_documents!=null', self.source)

    def test_raw_history_is_text_not_member_identity_or_external_link(self):
        raw = self.source.split('class _RecoveryDocumentPage', 1)[1].split('class _RecoveryMediaPage', 1)[0]
        self.assertIn('SelectableText(const JsonEncoder.withIndent(', raw)
        for forbidden in ('MemberAvatar(', 'Image.network(', 'launchUrl(', 'WebView', 'GestureRecognizer', 'Link('):
            self.assertNotIn(forbidden, self.source)
        self.assertIn('只读历史字段，不代表当前成员身份或授权', raw)

    def test_media_is_scoped_verified_then_opened_inside_app(self):
        media = self.source.split('Future<void> _openAsset(', 1)[1].split('Widget _media()', 1)[0]
        self.assertIn('asset.workspaceId!=workspaceId', media)
        self.assertIn('verifiedFile(workspaceId,asset.id)', media)
        self.assertIn('verifiedFile(workspaceId,asset.thumbnailId!)', media)
        self.assertNotRegex(media, r'(?<![A-Za-z0-9_])File\(')
        for forbidden in ('asset.path', 'Uri.parse', 'sourceOriginal', 'NativeMedia', 'getCurrentLocation'):
            self.assertNotIn(forbidden, media)
        self.assertIn('Image.file(widget.file', self.source)
        self.assertIn('VideoPlayerController.file(widget.file)', self.source)
        for forbidden in ('OpenFile', 'open_filex', 'Share.', 'launchUrl', 'VideoPlayerController.network', 'Image.network'):
            self.assertNotIn(forbidden, self.source)

    def test_incomplete_thumbnail_and_codec_states_are_not_complete_restore(self):
        self.assertIn('originalUnavailable=true', self.source)
        self.assertIn('此项不声明对应原件是否可用', self.source)
        self.assertIn('预览失败不表示文件缺失', self.source)
        self.assertIn('未确认是未改动原件', self.source)
        self.assertIn('不能称为完整整机恢复', self.source)
        self.assertIn('if(document.deleted)', self.source)

    def test_rebackup_requires_source_family_and_new_owned_device(self):
        backup = self.source.split('Future<void> _backup()', 1)[1].split('void _document(', 1)[0]
        self.assertIn('load(widget.workspace.id)', backup)
        self.assertIn('controller.familyId!=widget.workspace.sourceFamilyId', backup)
        self.assertIn('controller.deviceId!=widget.workspace.ownerDeviceId', backup)
        self.assertLess(backup.index('recovery_backup_identity_mismatch'), backup.index('LocalBackupPage(controller:controller)'))
        self.assertNotIn('controller.dispose(', self.source)

    def test_package_binding_status_and_excluded_public_are_visible(self):
        self.assertEqual(self.source.count('_packageNotice(plan.packageBound,plan.excludedPublicEntries)'), 2)
        self.assertIn('_packageNotice(workspace.packageBound,workspace.excludedPublicEntries,imported:true)', self.source)
        self.assertIn('_packageNotice(widget.workspace.packageBound,widget.workspace.excludedPublicEntries,imported:true)', self.source)
        self.assertIn('旧包未验证同包绑定，未关联公开文件 $excluded 项', self.source)
        self.assertIn('公开与内层可用文件会一并私有导入', self.source)
        self.assertIn('公开与内层可用文件已一并保存在本机私有资料库', self.source)
        self.assertIn('这不代表完整业务恢复', self.source)

    def test_video_is_not_autoplayed_and_controller_is_disposed(self):
        init = self.source.split('Future<void> _initializeVideo()', 1)[1].split('@override void dispose()', 1)[0]
        self.assertNotIn('.play()', init)
        self.assertIn('_video?.dispose()', self.source)
        self.assertIn('if(mounted)setState(()=>_ready=true)', init)

if __name__ == '__main__':
    unittest.main()
