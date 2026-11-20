"""回忆 UI 源码安全契约；不运行 Dart/Flutter/原生桥，不能证明编译或 UI 实测。"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class LocalMemoryUIContractTests(unittest.TestCase):
    def read(self, path):
        return (ROOT / path).read_text()

    def test_local_editor_is_selected_on_list_and_detail(self):
        for name in ('memory_list_page.dart', 'memory_detail_page.dart'):
            text = self.read('lib/features/plugins/memory/' + name)
            self.assertIn('api.isLocal', text)
            self.assertIn('LocalMemoryEditPage(', text)

    def test_thumbnail_and_original_are_authorized_before_files(self):
        text = self.read('lib/features/plugins/memory/local_memory_media.dart')
        check = text.split('Future<bool> localMemoryMediaVisible', 1)[1].split('Future<File?>', 1)[0]
        self.assertIn("runtime.memories.request('GET', familyId", check)
        self.assertIn("['memory', 'memories', media.memoryId]", check)
        self.assertIn('item.id == media.id && item.kind == media.kind', check)
        thumb = text.split('Future<File?> _authorizedThumbnail', 1)[1].split('Future<void>', 1)[0]
        self.assertLess(thumb.index('await localMemoryMediaVisible'), thumb.index('thumbnailFile('))
        original = text.split('Future<void> openLocalMemoryOriginal', 1)[1].split('class LocalMemoryThumbnail', 1)[0]
        self.assertLess(original.index('await localMemoryMediaVisible'), original.index('openOriginal('))
        for forbidden in ('native.read(', 'prepareOriginal(', 'CachedNetworkImage', 'DefaultCacheManager'):
            self.assertNotIn(forbidden, text)

    def test_thumbnail_does_not_display_old_future_during_reauthorization(self):
        text = self.read('lib/features/plugins/memory/local_memory_media.dart')
        self.assertIn('valueListenable: runtime.changes', text)
        self.assertIn('snapshot.connectionState != ConnectionState.done', text)
        self.assertIn('gaplessPlayback: false', text)
        self.assertIn('Image.file(', text)

    def test_gallery_keeps_local_media_out_of_network_gallery(self):
        text = self.read('lib/features/plugins/memory/memory_gallery_page.dart')
        item = text.split('itemBuilder: (context, i)', 1)[1]
        self.assertLess(item.index('if (api.isLocal)'), item.index('api.memoryMediaUrl(m)'))
        local = text.split('class _LocalMediaPage', 1)[1]
        self.assertIn('LocalMemoryThumbnail(', local)
        self.assertIn('openLocalMemoryOriginal(context, media)', local)
        self.assertNotIn('MemoryVideoPage(', local)
        self.assertIn('(_checkingLocal || !_localAllowed)', text)
        self.assertLess(text.index('(_checkingLocal || !_localAllowed)'), text.index('final total = widget.media.length'))

    def test_local_list_does_not_resurrect_old_private_tail(self):
        text = self.read('lib/features/plugins/memory/memory_list_page.dart')
        refresh = text.split('Future<void> _refreshSilently()', 1)[1].split('Future<void> _openEditor', 1)[0]
        local = refresh.split('if (_session.api.isLocal)', 1)[1].split('} else {', 1)[0]
        self.assertIn('_items = visible;', local)
        self.assertNotIn('...tail', local)
        self.assertIn('familyId == _session.currentFamilyId', local)
        self.assertIn('if (familyId == null || _session.api.isLocal) return;', text)
        self.assertIn('!session.api.isLocal && familyId != null', text)
        self.assertIn('epoch == _loadEpoch', text)

    def test_detail_drops_denied_content_and_preserves_author_avatar(self):
        text = self.read('lib/features/plugins/memory/memory_detail_page.dart')
        self.assertIn('changes.addListener(_localChanged)', text)
        self.assertIn('request == _accessRequest', text)
        self.assertIn('if (_accessLost)', text)
        self.assertEqual(text.count('authorAvatarUrl: m.authorAvatarUrl'), 2)
        self.assertIn('本机已授权的相册/文件原件不会被删除', text)

    def test_local_cache_entrypoints_return_before_preferences_or_network(self):
        text = self.read('lib/data/memory_cache.dart')
        for name in ('prewarmImages', 'warmFromDisk', 'warmOnLaunch', 'prefetch'):
            section = text.split('static Future<void> ' + name, 1)[1].split('static Future<void>', 1)[0]
            self.assertIn('api.isLocal', section)
            guard = section.index('api.isLocal')
            for call in ('load(familyId)', 'DefaultCacheManager()', 'save(familyId,', 'api.memories('):
                if call in section:
                    self.assertLess(guard, section.index(call))
        api = self.read('lib/data/wo_api.dart')
        self.assertIn('memoryMediaUrl(MemoryMedia m) => isLocal ? m.url', api)

    def test_editor_reauthorizes_and_invalidates_pending_actions_without_deleting_sources(self):
        text = self.read('lib/features/plugins/memory/local_memory_edit_page.dart')
        self.assertIn('runtime.changes.addListener(_permissionChanged)', text)
        self.assertIn('changes.removeListener(_permissionChanged)', text)
        self.assertIn('epoch==_authorityEpoch', text)
        self.assertIn('if(item==null||!_at(epoch))return;', text)
        self.assertGreaterEqual(text.count('_require(epoch);'), 8)
        self.assertIn('_accessBlocked||(!_initializing&&!_sameIdentity)', text)
        self.assertIn('私有草稿仍保留', text)
        self.assertNotIn('.delete(', text)
        self.assertNotIn('.release(', text)
        self.assertIn("runtime.memories.access.spaceFor(fid,_visibility)", text)

    def test_legacy_save_and_video_fail_closed_for_local_thumbnail(self):
        save = self.read('lib/features/plugins/memory/memory_save.dart')
        self.assertLess(save.index("scheme == 'wo-local-media'"), save.index('Gal.hasAccess('))
        video = self.read('lib/features/plugins/memory/memory_video_page.dart')
        self.assertLess(video.index('if (api.isLocal || uri == null'), video.index('VideoPlayerController.networkUrl('))

if __name__ == '__main__':
    unittest.main()
