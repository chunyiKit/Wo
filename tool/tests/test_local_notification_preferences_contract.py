"""仅本机站内偏好源码与独立SQLite模型；不执行Dart/SDK/OS推送。"""
from pathlib import Path
import json
import sqlite3
import unittest

ROOT=Path(__file__).resolve().parents[2]
API=(ROOT/'lib/local/local_api.dart').read_text()
HELPER=(ROOT/'lib/local/local_notification_preferences.dart').read_text()
PAGE=(ROOT/'lib/features/profile/notification_prefs_page.dart').read_text()


def parse(raw):
    if raw is None:
        return True,True
    if not isinstance(raw,dict) or 'push_enabled' in raw and type(raw['push_enabled']) is not bool:
        return False,False
    enabled=raw.get('push_enabled',True)
    if 'sources' not in raw:
        return enabled,True
    source=raw['sources']
    if not isinstance(source,dict) or 'expiry' in source and type(source['expiry']) is not bool:
        return False,False
    return enabled,source.get('expiry',True)


def patch(db,change):
    with db:
        row=db.execute('SELECT value FROM meta WHERE key=?',['private:notification-preferences']).fetchone()
        enabled,expiry=parse(json.loads(row[0]) if row else None)
        value={'push_enabled':change.get('push_enabled',enabled),'sources':{'expiry':change.get('sources',{}).get('expiry',expiry)}}
        db.execute('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',['private:notification-preferences',json.dumps(value)])
        return value


class SourceContract(unittest.TestCase):
    def test_defaults_are_real_local_capability_and_os_is_false(self):
        self.assertIn('defaults=LocalNotificationPreferences(enabled:true,expirySourceEnabled:true)',HELPER)
        self.assertIn("'system_push_supported':false",HELPER)
        self.assertIn("'delivery':'local_message_center'",HELPER)
        self.assertIn('expiryEnabled=>enabled&&expirySourceEnabled',HELPER)
    def test_prefs_are_private_and_update_is_transactional(self):
        source=API.split('Future<Json> _updateNotificationPreferences',1)[1].split('Future<List<Json>> _installedList',1)[0]
        self.assertIn('store.db.transaction((tx)async',source)
        self.assertIn("private:${LocalNotificationPreferences.privateKey}",source)
        self.assertNotIn('store.patch(',source)
        self.assertNotIn('store.merge(',source)
        self.assertIn('next.toPrivateValue()',source)
    def test_only_total_and_expiry_patch_supported(self):
        source=API.split('Future<Json> _updateNotificationPreferences',1)[1].split('Future<List<Json>> _installedList',1)[0]
        self.assertIn("{'push_enabled','sources'}",source)
        self.assertIn("sources.keys.any((key)=>key!='expiry')",source)
        self.assertIn('sources.values.any((value)=>value is! bool)',source)
        self.assertIn("data['push_enabled'] is! bool",source)
    def test_local_ui_does_not_promise_push_and_serializes_save(self):
        self.assertIn("local ? '本机站内提醒'",PAGE)
        self.assertIn('当前仅控制到期物品的新站内提醒，不控制系统推送',PAGE)
        self.assertIn('其它成员设备的设置不受影响',PAGE)
        self.assertIn('已有消息、已读和隐藏历史保留',PAGE)
        self.assertIn('if (local) setState(() => _saving = true)',PAGE)
        self.assertIn('if (prev == null || _saving) return',PAGE)
        self.assertIn("local ? '本机设置读取失败，请重试。'",PAGE)
    def test_get_has_explicit_source_and_malformed_fail_closed(self):
        self.assertIn("'key':'expiry'",HELPER)
        self.assertIn("on FormatException{return LocalNotificationPreferences.disabled;}",API)
        self.assertIn("value.containsKey('push_enabled')&&value['push_enabled'] is! bool",HELPER)
        self.assertIn("sources.containsKey('expiry')&&sources['expiry'] is! bool",HELPER)
    def test_patch_cannot_delete_history_or_affect_peer(self):
        source=API.split('Future<Json> _updateNotificationPreferences',1)[1].split('Future<List<Json>> _installedList',1)[0]
        self.assertNotIn('notifications',source)
        self.assertNotIn('.delete(',source)
        self.assertNotIn('documents',source)
        prepared=(ROOT/'test/local/local_notification_preferences_test.dart').read_text()
        self.assertEqual(prepared.count("  test('"),7)
        self.assertIn('A私有偏好不进入peer操作，不影响B开关',prepared)


class SqliteModels(unittest.TestCase):
    def test_sqlite_private_source_then_total_patch_keeps_both(self):
        a=sqlite3.connect(':memory:');a.execute('CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)')
        patch(a,{'sources':{'expiry':False}});patch(a,{'push_enabled':False});value=patch(a,{'push_enabled':True})
        self.assertEqual(value,{'push_enabled':True,'sources':{'expiry':False}});a.close()
    def test_two_databases_do_not_share_private_preferences(self):
        a=sqlite3.connect(':memory:');b=sqlite3.connect(':memory:')
        for db in (a,b):
            db.execute('CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)')
        patch(a,{'push_enabled':False})
        self.assertIsNone(b.execute('SELECT value FROM meta').fetchone())
        self.assertEqual(parse(None),(True,True));a.close();b.close()
    def test_sqlite_failure_preserves_old_settings(self):
        db=sqlite3.connect(':memory:');db.execute('CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)')
        patch(db,{'sources':{'expiry':False}});old=db.execute('SELECT value FROM meta').fetchone()[0]
        db.execute("CREATE TRIGGER reject_prefs BEFORE INSERT ON meta BEGIN SELECT RAISE(ABORT,'synthetic'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            patch(db,{'push_enabled':False})
        self.assertEqual(db.execute('SELECT value FROM meta').fetchone()[0],old);db.close()
    def test_malformed_config_does_not_turn_delivery_on(self):
        for value in (False,{'push_enabled':None},{'push_enabled':1},{'sources':None},{'sources':{'expiry':None}}):
            self.assertEqual(parse(value),(False,False))
        self.assertEqual(parse({'push_enabled':False,'sources':{'expiry':True}}),(False,True))


if __name__=='__main__':
    unittest.main()
