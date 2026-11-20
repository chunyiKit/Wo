"""手机集成的纯Python静态契约与独立权限模型。

不启动Dart/Flutter/SDK、旧test_chat_pagination.py、浏览器或网络。
通过不等于Dart analyze、原生编译或实际手机协议互通。
"""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def body(source, anchor):
    start = source.index('{', source.index(anchor))
    depth, i = 1, start + 1
    while depth and i < len(source):
        if source.startswith('//', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end + 1
            continue
        if source[i] in "'\"":
            quote = source[i]
            triple = source.startswith(quote * 3, i)
            end = quote * (3 if triple else 1)
            i += len(end)
            while i < len(source) and not source.startswith(end, i):
                i += 2 if source[i] == '\\' else 1
            if i == len(source):
                raise AssertionError('Unclosed source string')
            i += len(end)
            continue
        if source[i] == '{':
            depth += 1
        elif source[i] == '}':
            depth -= 1
        i += 1
    if depth:
        raise AssertionError('Unclosed source block')
    return source[start + 1:i - 1]


def schemas(source, anchor):
    return {name: set(re.findall(r"'([^']+)'", fields))
            for name, fields in re.findall(r"'([^']+)'\s*:\s*\{([^}]*)\}", body(source, anchor))}


class MobileRuntimeContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = (ROOT / 'lib/local/local_runtime.dart').read_text()
        cls.api = (ROOT / 'lib/local/local_api.dart').read_text()
        cls.snapshot = (ROOT / 'lib/local/backup/local_backup_snapshot.dart').read_text()
        cls.prepared = (ROOT / 'test/local/backup/local_backup_snapshot_test.dart').read_text()
        cls.policy = (ROOT / 'lib/local/sync/sync_policy.dart').read_text()
        cls.plugins = {}
        for path in (ROOT / 'lib/local/plugins').glob('*.dart'):
            source = path.read_text()
            for name in re.findall(r'class\s+(\w+Routes)\b', source):
                cls.plugins[name] = source
        cls.registered = set(re.findall(r'\b(\w+Routes)\(store', cls.api + cls.runtime))
        cls.base = schemas(cls.policy, 'static const baseSchemas=')
        cls.merged = {key: set(value) for key, value in cls.base.items()}
        for name in cls.registered:
            source = cls.plugins[name]
            if 'static const syncFields' in source:
                for key, fields in schemas(source, 'static const syncFields').items():
                    cls.merged.setdefault(key, set()).update(fields)

    def test_every_registered_journal_module_contributes_its_schema(self):
        for name in self.registered:
            source = self.plugins[name]
            if 'static const syncFields' in source:
                self.assertIn(name + '.syncFields', self.runtime, name + ' dispatcher has no registered sync schema')
        for collection in ('family', 'members', 'installed', 'plugins/chat/messages', 'plugins/chat/status',
                           'plugins/memory/memories', 'plugins/memory/media', 'plugins/stock/events',
                           'plugins/accounting/transactions', 'plugins/calendar/items'):
            self.assertIn(collection, self.merged)
        self.assertIn('LocalIncrementalStrategy.commentFields', self.snapshot)

    def test_schema_union_preserves_all_shared_notification_fields(self):
        union = body(self.runtime, 'get syncSchemas')
        self.assertIn('...?result[entry.key]', union)
        self.assertIn('...entry.value', union)
        self.assertIn('Map.unmodifiable(result)', union)
        self.assertTrue({'type', 'title', 'body', 'created_by', 'created_at', 'status', 'recipient_ids',
                         'source_plugin', 'source_id', 'source_occurrence'}.issubset(self.merged['notifications']))
        forbidden = {'locator', 'bookmark', 'asset_id', 'original_uri', 'original_bytes',
                     'original_handle', 'source_uri', 'file_path', 'api_key', 'access_token', 'secret', 'password'}
        for collection, fields in self.merged.items():
            self.assertFalse(fields & forbidden, collection)

    def test_recipe_and_expiry_actual_journal_paths_have_adapters(self):
        source = self.plugins['RecipeExpiryRoutes']
        paths = set(re.findall(r"/families/\$fid/(plugins/(?:recipe|expiry)/[a-z]+)", source))
        self.assertTrue({'plugins/recipe/recipes', 'plugins/recipe/tags', 'plugins/recipe/settings', 'plugins/expiry/items'}.issubset(paths))
        self.assertTrue(paths.issubset(self.base))
        recipe_fields = set(re.findall(r"'([^']+)'", body(source, 'static const _recipeFields =')))
        expiry_fields = set(re.findall(r"'([^']+)'", body(source, 'static const _expiryFields =')))
        self.assertTrue(recipe_fields.issubset(self.base['plugins/recipe/recipes']))
        self.assertTrue(expiry_fields.issubset(self.base['plugins/expiry/items']))

    def test_current_member_and_per_scope_parent_authorize_snapshot_before_selection(self):
        create = body(self.snapshot, 'Future<BackupSnapshot> create(')
        self.assertLess(create.index("member['status']!='active'"), create.index('memories.visibleSnapshot(familyId)'))
        self.assertLess(create.index('memories.visibleSnapshot(familyId)'), create.index("query('documents'"))
        for guard in ("member['family_id']!=familyId", "member['user_id']!=store.deviceId", 'access.visibleSpaces(familyId)',
                      'scope!=familyId&&!memory&&!descriptor&&!isComment', "parent['family_id']!=familyId",
                      "access.spaceFor(familyId,parent['visibility'] as String)", 'expected!=scope',
                      "parent['visibility']=='private'&&parent['created_by']!=store.deviceId",
                      "meta['scope']!=bound.space||meta['memory_id']!=row['memory_id']"):
            self.assertIn(guard, create)
        self.assertLess(create.index('validatePortableFields('), create.index('selected.add('))

    def test_records_are_restricted_and_neither_database_nor_native_identity_is_exported(self):
        create = body(self.snapshot, 'Future<BackupSnapshot> create(')
        for forbidden in ("query('meta'", "query('device_refs'", "query('operations'", 'store.db.path', '...ref', '...meta'):
            self.assertNotIn(forbidden, create)
        self.assertIn("selected.add({'space':scope,'collection':collection,'id':id,'fields':fields})", create)
        self.assertIn("'records',records,BackupPrivacy.restricted", create)
        self.assertIn('bound.space==familyId?BackupPrivacy.public:BackupPrivacy.restricted', create)
        self.assertIn('snapshot_unknown_fields', create)
        self.assertIn('records_applied', create)
        for forbidden_key in ('locator', 'bookmark', 'asset_id', 'api_key', 'access_token', 'password'):
            self.assertIn("'" + forbidden_key + "'", self.policy)

    def test_missing_originals_and_omitted_modules_cannot_look_like_complete_restore(self):
        for required in ('snapshot_document_limit', 'snapshot_record_limit', 'omitted.add(suffix)',
                         '_MissingSource(', 'media.prepareBackupSource(', 'kindIfMissing:',
                         '尚未安全导入业务库', '失效授权或离线云端文件会明确缺件'):
            self.assertIn(required, self.snapshot)
        self.assertIn("'source_unavailable'", self.snapshot)
        self.assertIn("sourceExact:false,missing:", self.snapshot)
        for fixture in ('已授权私密正文只在受限惰性records中', '无本地有效成员时备份失败', '未知集合明确记录遗漏'):
            self.assertIn(fixture, self.prepared)

    def test_backup_is_lazy_family_bound_and_does_not_block_local_bootstrap(self):
        opening = body(self.runtime, 'static Future<LocalRuntime> _open()')
        self.assertNotIn('MobileBackupController.native(', opening)
        self.assertNotIn('backupController', opening)
        self.assertNotIn('controller.load()', opening)
        lazy = body(self.runtime, 'get backupController')
        self.assertIn('final fid=api.familyId', lazy)
        self.assertIn('_backupControllers.putIfAbsent(fid', lazy)
        self.assertIn('SqliteBackupPreferences(store,fid)', lazy)
        self.assertIn('snapshotProvider:()=>LocalBackupSnapshots(', lazy)
        self.assertIn('_backupControllers.remove(fid)', lazy)
        self.assertIn('snapshotProvider', lazy)
        self.assertIn('ApiClient.localBackend=api', opening)

    def test_foreground_processing_stops_sync_on_background_and_never_claims_delivery(self):
        foreground = body(self.runtime, 'Future<void> foreground(bool active)')
        self.assertIn('if(active)', foreground)
        self.assertIn('await sync.start()', foreground)
        self.assertIn('else{await sync.stop();}', foreground)
        self.assertIn('requestDueAnniversaryReminders', foreground)
        self.assertIn('requestDueReminders', foreground)
        notifications = body(self.api, 'Future<List<Json>> _notifications()')
        self.assertIn("'delivery_status':row['status']??'pending_local_delivery'", notifications)
        self.assertIn('notification-hidden:', notifications)
        for name in ('MovieChoreAnniversaryRoutes', 'CalendarRoutes'):
            self.assertIn("'pending_local_delivery'", self.plugins[name])
            self.assertNotRegex(self.plugins[name], r"'status'\s*:\s*'(sent|delivered)'")
        prefs = self.api.split("path=='/me/notification-preferences' && method=='PATCH'", 1)[1].split('else if(', 1)[0]
        self.assertIn('LOCAL_MODULE_PENDING', prefs)

    def test_local_member_guard_binds_both_family_and_identity(self):
        joined = body(self.api, 'Future<void> _joined(')
        self.assertRegex(joined, r"member\[\s*'family_id'\s*\]\s*!=\s*fid")
        self.assertRegex(joined, r"member\[\s*'user_id'\s*\]\s*!=\s*store\.deviceId")

    def test_bootstrap_filters_revoked_families_without_overwriting_known_local_data(self):
        active = body(self.api, 'get families async')
        for guard in ("member['status']=='active'", "member['family_id']==fid", "member['user_id']==store.deviceId", "['owner','member'].contains(member['role'])"):
            self.assertIn(guard, active)
        self.assertIn("await store.get(fid,_col(fid,'family'),fid)!=null", active)
        initialize = body(self.api, 'Future<void> initialize()')
        self.assertIn('(await _knownFamilies).isEmpty', initialize)
        self.assertNotIn('(await families).isEmpty', initialize)
        selection = body(self.api, 'Future<void> _selectActiveFamily()')
        self.assertIn('active.contains(preferred)?preferred:active.firstOrNull', selection)
        self.assertIn("store.setPrivate('current-family',familyId)", selection)
        self.assertIn("if(['/me/bootstrap','/me','/me/families'].contains(uri.path))await _selectActiveFamily();", self.api)
        for function in ('Future<Json> _family(', 'Future<Json> _installed('):
            self.assertIn('await _joined(fid)', body(self.api, function))
        fixtures = (ROOT / 'test/local/mobile_runtime_access_test.dart').read_text()
        self.assertEqual(len(re.findall(r"\btest\(", fixtures)), 5)
        for fixture in ('撤权后bootstrap不显示旧家庭卡片', '有效备用家庭', '旧私有outbox', '私密计数或标题', '家庭未读计数从当前设备的本地通知与已读状态派生'):
            self.assertIn(fixture, fixtures)

    def test_independent_three_member_permission_model_keeps_private_and_couple_out_of_public(self):
        family = 'f1'
        docs = [
            {'scope': family, 'id': 'shared', 'family': family, 'visibility': 'family', 'creator': 'a', 'title': 'shared-title'},
            {'scope': 'p_a', 'id': 'secret-a', 'family': family, 'visibility': 'private', 'creator': 'a', 'title': 'secret-title-a'},
            {'scope': 'p_b', 'id': 'secret-b', 'family': family, 'visibility': 'private', 'creator': 'b', 'title': 'secret-title-b'},
            {'scope': 'c_ab', 'id': 'couple', 'family': family, 'visibility': 'couple', 'creator': 'a', 'title': 'couple-title'},
            {'scope': family, 'id': 'wrong-public', 'family': family, 'visibility': 'private', 'creator': 'a', 'title': 'bad-private-in-public'},
            {'scope': 'p_a', 'id': 'forged', 'family': family, 'visibility': 'private', 'creator': 'b', 'title': 'not-owned'},
            {'scope': family, 'id': 'wrong-family', 'family': 'f2', 'visibility': 'family', 'creator': 'a', 'title': 'cross-family'},
        ]
        for viewer in ('a', 'b', 'c'):
            spaces = {family, 'p_' + viewer} | ({'c_ab'} if viewer in ('a', 'b') else set())
            def expected(row):
                return family if row['visibility'] == 'family' else 'p_' + viewer if row['visibility'] == 'private' else 'c_ab'
            visible = [row for row in docs if row['scope'] in spaces and row['family'] == family
                       and expected(row) == row['scope'] and (row['visibility'] != 'private' or row['creator'] == viewer)]
            selected = json.dumps(visible)
            self.assertNotIn('bad-private-in-public', selected)
            self.assertNotIn('cross-family', selected)
            self.assertNotIn('not-owned', selected)
            if viewer != 'a': self.assertNotIn('secret-title-a', selected)
            if viewer == 'c': self.assertNotIn('couple-title', selected)
            public_thumbs = [dict(id=row['id'], kind='thumbnail') for row in visible if row['scope'] == family]
            public_manifest = json.dumps(public_thumbs + [{'id': 'opaque-archive', 'kind': 'sealed'}])
            for secret in ('secret-title-a', 'secret-title-b', 'couple-title', 'p_a', 'p_b', 'c_ab'):
                self.assertNotIn(secret, public_manifest)

if __name__ == '__main__':
    unittest.main()
