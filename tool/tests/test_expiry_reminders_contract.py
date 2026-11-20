"""到期提醒源码契约+独立Python/真实SQLite模型，不执行Dart，不证明Timer或系统投递。"""
from pathlib import Path
from datetime import date
import json
import sqlite3
import tempfile
import threading
import unittest
import uuid

ROOT=Path(__file__).resolve().parents[2]
ROUTE=(ROOT/'lib/local/plugins/recipe_expiry.dart').read_text()
METHOD=ROUTE.split('Future<int> requestDueExpiryReminders(',1)[1]
HELPER=(ROOT/'lib/local/local_foreground_reminders.dart').read_text()
RUNTIME=(ROOT/'lib/local/local_runtime.dart').read_text()
UI=(ROOT/'lib/features/plugins/expiry/expiry_page.dart').read_text()
ACTIVE_WHERE='space=? AND collection=? AND deleted=0'
SEEN_WHERE='space=? AND collection=? AND id=?'
FAMILY='family'; DEVICE='device'; NOTICES=f'/families/{FAMILY}/notifications'

def put(db,col,identity,fields,deleted=0):
    db.execute('INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?)',(FAMILY,col,identity,json.dumps(fields),deleted))

def connection(path):
    db=sqlite3.connect(path,timeout=5)
    db.execute('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)')
    db.execute('CREATE TABLE IF NOT EXISTS documents(space TEXT,collection TEXT,id TEXT,data TEXT,deleted INTEGER,PRIMARY KEY(space,collection,id))')
    return db

def seed(db):
    put(db,f'/families/{FAMILY}/members',DEVICE,{'family_id':FAMILY,'user_id':DEVICE,'status':'active'})
    put(db,f'/families/{FAMILY}/installed','card',{'plugin_id':'expiry','enabled':True})
    db.commit()

def item(db,identity='item',**extra):
    fields={'family_id':FAMILY,'active':True,'notify_enabled':True,'notify_days_before':30,'expire_on':'2026-12-20',**extra}
    put(db,f'/families/{FAMILY}/plugins/expiry/items',identity,fields);db.commit()

def private_preference(db,value):
    if value is None:db.execute("DELETE FROM meta WHERE key='private:notification-preferences'")
    else:db.execute('INSERT OR REPLACE INTO meta VALUES(?,?)',['private:notification-preferences',json.dumps(value)])
    db.commit()

def preference_enabled(db):
    row=db.execute("SELECT value FROM meta WHERE key='private:notification-preferences'").fetchone()
    if row is None:return True
    try:value=json.loads(row[0])
    except ValueError:return False
    if value is None:return True
    if not isinstance(value,dict):return False
    enabled=value.get('push_enabled')
    if enabled is not None and type(enabled) is not bool:return False
    enabled=True if enabled is None else enabled
    sources=value.get('sources')
    if sources is None:return enabled
    if isinstance(sources,dict):
        expiry=sources.get('expiry')
        if expiry is not None and type(expiry) is not bool:return False
        return enabled and (True if expiry is None else expiry)
    if isinstance(sources,list):
        expiry=True
        for source in sources:
            if not isinstance(source,dict):return False
            if source.get('key')=='expiry':
                if type(source.get('enabled')) is not bool:return False
                expiry=source['enabled']
        return enabled and expiry
    return False

def copy_documents(source,target):
    # Independent document-only copy model, not the Dart operation protocol.
    # Private meta deliberately never crosses device databases.
    with target:
        for row in source.execute('SELECT space,collection,id,data,deleted FROM documents'):
            target.execute('INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?)',row)

def visible(db,viewer):
    return [json.loads(row[0]) for row in db.execute('SELECT data FROM documents WHERE collection=? AND deleted=0',[NOTICES])
            if viewer in json.loads(row[0])['recipient_ids']]

def run_model(db,today,device=DEVICE):
    """独立规则模型，只验证实际SQLite隔离/回滚与日期/UUID语义。"""
    db.execute('BEGIN IMMEDIATE')
    try:
        def rows(col):
            return [(identity,json.loads(raw)) for identity,raw in db.execute(f'SELECT id,data FROM documents WHERE {ACTIVE_WHERE}',[FAMILY,col])]
        members=rows(f'/families/{FAMILY}/members')
        def active(pair):
            identity,fields=pair
            return fields.get('family_id')==FAMILY and fields.get('user_id')==identity and fields.get('status')=='active'
        if not any(identity==device and active((identity,fields)) for identity,fields in members):
            raise PermissionError('inactive device')
        if not preference_enabled(db):db.commit();return 0
        if not any(fields.get('plugin_id')=='expiry' and fields.get('enabled') is True for _,fields in rows(f'/families/{FAMILY}/installed')):
            db.commit();return 0
        count=0
        for identity,fields in sorted(rows(f'/families/{FAMILY}/plugins/expiry/items')):
            if fields.get('family_id')!=FAMILY or fields.get('active') is not True:continue
            try:delta=(date.fromisoformat(fields['expire_on'])-today).days
            except ValueError:continue
            if delta>=0 and (not fields['notify_enabled'] or delta>fields['notify_days_before']):continue
            kind='expiry_expired' if delta<0 else 'expiry_due'
            notice=str(uuid.uuid5(uuid.NAMESPACE_URL,f"expiry:{FAMILY}:{identity}:{fields['expire_on']}:{kind}:{device}"))
            if db.execute(f'SELECT id FROM documents WHERE {SEEN_WHERE}',[FAMILY,NOTICES,notice]).fetchone():continue
            put(db,NOTICES,notice,{'type':kind,'source_id':identity,'status':'pending_local_delivery','recipient_ids':[device],'created_by':device,'source_occurrence':fields['expire_on']})
            count+=1
            if count==256:break
        db.commit();return count
    except BaseException:
        db.rollback();raise

class SourceContract(unittest.TestCase):
    def test_same_transaction_rechecks_members_install_and_tombstones(self):
        self.assertIn('store.batchComputed((tx) async',METHOD)
        self.assertIn(ACTIVE_WHERE,METHOD);self.assertIn(SEEN_WHERE,METHOD)
        self.assertLess(METHOD.index("documents('/families/$fid/members')"),METHOD.index('requests.add('))
        self.assertLess(METHOD.index("row['plugin_id'] == 'expiry'"),METHOD.index('requests.add('))
        self.assertIn('if (previous.isNotEmpty) continue',METHOD)
    def test_local_calendar_and_two_stage_baseline(self):
        self.assertIn('DateTime.utc(now.year, now.month, now.day)',METHOD)
        self.assertIn('final overdue = delta < 0',METHOD)
        self.assertIn('if (!overdue && (!enabled || delta > ahead)) continue',METHOD)
        self.assertIn("'expiry_expired' : 'expiry_due'",METHOD)
    def test_stable_id_current_recipients_and_no_system_delivery(self):
        self.assertIn("'expiry:$fid:${row['id']}:$due:$type:${store.deviceId}'",METHOD)
        self.assertIn("member['user_id'] == member['id']",METHOD)
        self.assertIn("'status': 'pending_local_delivery'",METHOD)
        self.assertIn('final recipients = <String>[store.deviceId]',METHOD)
        self.assertNotIn('if (activeMember(m))',METHOD)
        self.assertIn('if (requests.length == 256) break',METHOD)
        for forbidden in ('Timer(', 'NotificationManager','UNUserNotificationCenter','schedule(', 'http.', 'expire_on\'] ='):
            self.assertNotIn(forbidden,METHOD)
    def test_existing_foreground_timer_includes_expiry_and_stops_in_background(self):
        self.assertIn("'expiry': RecipeExpiryRoutes(store, now: now).requestDueExpiryReminders",HELPER)
        self.assertIn("'expiry': {'expiry'}",HELPER)
        self.assertIn('Timer.periodic(const Duration(minutes:1)',RUNTIME)
        self.assertIn('_foregroundReminderTimer?.cancel()',RUNTIME)
        self.assertIn('isActive:()=>epoch==_foregroundEpoch',RUNTIME)
    def test_private_preference_gate_uses_same_transaction_and_shared_helper(self):
        self.assertIn("tx.query('meta', columns: ['value']",METHOD)
        self.assertIn("'private:${LocalNotificationPreferences.privateKey}'",METHOD)
        self.assertIn('LocalNotificationPreferences.fromPrivateValue(rawPreferences).expiryEnabled',METHOD)
        self.assertLess(METHOD.index('expiryEnabled'),METHOD.index('requests.add('))
        self.assertIn("import '../local_notification_preferences.dart';",ROUTE)

    def test_local_ui_does_not_claim_os_push_and_remote_text_is_preserved(self):
        self.assertIn('WoScope.api(context).isLocal',UI)
        self.assertIn('当前不投递系统通知',UI)
        self.assertIn('关闭仅暂停到期前消息',UI)
        self.assertIn("'开启后会在到期前推送通知'",UI)

class SqliteModel(unittest.TestCase):
    def setUp(self):
        self.folder=tempfile.TemporaryDirectory();self.path=Path(self.folder.name)/'model.sqlite';self.db=connection(self.path);seed(self.db)
    def tearDown(self):self.db.close();self.folder.cleanup()
    def test_window_today_and_overdue_only_once(self):
        item(self.db);self.assertEqual(run_model(self.db,date(2026,11,19)),0);self.assertEqual(run_model(self.db,date(2026,11,20)),1)
        self.assertEqual(run_model(self.db,date(2026,12,20)),0);self.assertEqual(run_model(self.db,date(2026,12,21)),1);self.assertEqual(run_model(self.db,date(2026,12,22)),0)
    def test_disabled_pre_and_paused_all_and_leap_boundary(self):
        item(self.db,'muted',notify_enabled=False,expire_on='2028-02-29');item(self.db,'paused',active=False,expire_on='2028-02-28')
        self.assertEqual(run_model(self.db,date(2028,2,29)),0);self.assertEqual(run_model(self.db,date(2028,3,1)),1)
        item(self.db,'zero',notify_days_before=0,expire_on='2028-03-02');self.assertEqual(run_model(self.db,date(2028,3,1)),0);self.assertEqual(run_model(self.db,date(2028,3,2)),1)
    def test_current_recipients_and_tombstone_survive_reopen(self):
        item(self.db);put(self.db,f'/families/{FAMILY}/members','active',{'user_id':'active','family_id':FAMILY,'status':'active'})
        put(self.db,f'/families/{FAMILY}/members','left',{'user_id':'left','family_id':FAMILY,'status':'left'});self.db.commit()
        self.assertEqual(run_model(self.db,date(2026,11,20)),1);identity,raw=self.db.execute('SELECT id,data FROM documents WHERE collection=?',[NOTICES]).fetchone();self.assertEqual(json.loads(raw)['recipient_ids'],[DEVICE])
        self.db.execute('UPDATE documents SET deleted=1 WHERE collection=? AND id=?',[NOTICES,identity]);self.db.commit();self.db.close();self.db=connection(self.path)
        self.assertEqual(run_model(self.db,date(2026,11,20)),0)
    def test_transaction_rolls_back_after_first_notice_and_retry(self):
        item(self.db,'a');item(self.db,'b');self.db.execute(f"CREATE TRIGGER fail_second BEFORE INSERT ON documents WHEN NEW.collection='{NOTICES}' AND instr(NEW.data,'\"source_id\": \"b\"')>0 BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):run_model(self.db,date(2026,11,20))
        self.assertEqual(self.db.execute('SELECT count(*) FROM documents WHERE collection=?',[NOTICES]).fetchone()[0],0)
        self.db.execute('DROP TRIGGER fail_second');self.assertEqual(run_model(self.db,date(2026,11,20)),2)
    def test_two_real_sqlite_connections_do_not_publish_duplicate_id(self):
        item(self.db);results=[];failures=[]
        def work():
            db=connection(self.path)
            try:results.append(run_model(db,date(2026,11,20)))
            except BaseException as error:failures.append(error)
            finally:db.close()
        threads=[threading.Thread(target=work) for _ in range(2)]
        for thread in threads:thread.start()
        for thread in threads:thread.join()
        self.assertEqual(failures,[]);self.assertEqual(sorted(results),[0,1]);self.assertEqual(self.db.execute('SELECT count(*) FROM documents WHERE collection=?',[NOTICES]).fetchone()[0],1)
    def test_two_devices_have_distinct_fixed_authors_and_one_visible_each(self):
        item(self.db);peer='peer-device'
        put(self.db,f'/families/{FAMILY}/members',peer,{'user_id':peer,'family_id':FAMILY,'status':'active'});self.db.commit()
        self.assertEqual(run_model(self.db,date(2026,11,20),DEVICE),1)
        self.assertEqual(run_model(self.db,date(2026,11,20),peer),1)
        rows=[(identity,json.loads(raw)) for identity,raw in self.db.execute('SELECT id,data FROM documents WHERE collection=?',[NOTICES])]
        self.assertEqual(len({identity for identity,_ in rows}),2)
        for viewer in (DEVICE,peer):
            visible=[row for _,row in rows if viewer in row['recipient_ids']]
            self.assertEqual(len(visible),1);self.assertEqual(visible[0]['created_by'],viewer)
            self.assertEqual(run_model(self.db,date(2026,11,20),viewer),0)

    def test_a_pre_then_b_first_overdue_uses_two_sqlite_clocks_no_a_projection(self):
        peer=connection(Path(self.folder.name)/'peer-clock.sqlite');peer_id='peer'
        try:
            put(self.db,f'/families/{FAMILY}/members',peer_id,{'user_id':peer_id,'family_id':FAMILY,'status':'active'});self.db.commit()
            item(self.db,expire_on='2026-11-21',notify_days_before=1)
            self.assertEqual(run_model(self.db,date(2026,11,20)),1);copy_documents(self.db,peer)
            self.assertEqual(visible(peer,peer_id),[])
            self.assertEqual(run_model(peer,date(2026,11,22),peer_id),1)
            self.assertEqual([(n['type'],n['created_by'],n['source_occurrence']) for n in visible(peer,peer_id)],[('expiry_expired',peer_id,'2026-11-21')])
            self.assertEqual(run_model(peer,date(2026,11,22),peer_id),0)
        finally:peer.close()

    def test_date_moved_future_gives_new_round_on_two_distinct_sqlite_clocks(self):
        peer=connection(Path(self.folder.name)/'peer-future.sqlite');peer_id='peer'
        try:
            put(self.db,f'/families/{FAMILY}/members',peer_id,{'user_id':peer_id,'family_id':FAMILY,'status':'active'});self.db.commit()
            item(self.db,expire_on='2026-11-21',notify_days_before=1)
            self.assertEqual(run_model(self.db,date(2026,11,20)),1);copy_documents(self.db,peer);self.assertEqual(run_model(peer,date(2026,11,22),peer_id),1)
            item(self.db,expire_on='2026-12-20',notify_days_before=30)
            self.assertEqual(run_model(self.db,date(2026,11,20)),1);copy_documents(self.db,peer);self.assertEqual(run_model(peer,date(2026,11,22),peer_id),1)
            self.assertEqual({(n['type'],n['source_occurrence']) for n in visible(peer,peer_id)},{('expiry_expired','2026-11-21'),('expiry_due','2026-12-20')})
            self.assertEqual(run_model(peer,date(2026,11,22),peer_id),0)
        finally:peer.close()

    def test_master_source_and_bad_private_preferences_block_new_only(self):
        item(self.db);self.assertEqual(run_model(self.db,date(2026,11,20)),1);item(self.db,'later')
        for prefs in ({'push_enabled':False,'sources':{'expiry':True}},{'push_enabled':True,'sources':{'expiry':False}},{'push_enabled':'true','sources':{'expiry':True}}):
            private_preference(self.db,prefs);self.assertEqual(run_model(self.db,date(2026,11,20)),0);self.assertEqual(len(visible(self.db,DEVICE)),1)
        self.db.execute("UPDATE meta SET value='not-json' WHERE key='private:notification-preferences'");self.db.commit()
        self.assertEqual(run_model(self.db,date(2026,11,20)),0);private_preference(self.db,None);self.assertEqual(run_model(self.db,date(2026,11,20)),1)

    def test_private_switch_stays_on_a_and_does_not_disable_b(self):
        peer=connection(Path(self.folder.name)/'peer-prefs.sqlite');peer_id='peer'
        try:
            put(self.db,f'/families/{FAMILY}/members',peer_id,{'user_id':peer_id,'family_id':FAMILY,'status':'active'});self.db.commit();item(self.db)
            private_preference(self.db,{'push_enabled':False,'sources':{'expiry':True}});copy_documents(self.db,peer)
            self.assertEqual(run_model(self.db,date(2026,11,20)),0);self.assertEqual(run_model(peer,date(2026,11,20),peer_id),1)
            self.assertEqual(peer.execute('SELECT count(*) FROM meta').fetchone()[0],0)
            private_preference(self.db,{'push_enabled':True,'sources':{'expiry':True}});self.assertEqual(run_model(self.db,date(2026,11,20)),1)
        finally:peer.close()

    def test_batch_limit_continues_and_inactive_install_blocks(self):
        for i in range(257):item(self.db,f'{i:03}')
        self.assertEqual(run_model(self.db,date(2026,11,20)),256);self.assertEqual(run_model(self.db,date(2026,11,20)),1);self.assertEqual(run_model(self.db,date(2026,11,20)),0)
        put(self.db,f'/families/{FAMILY}/installed','card',{'plugin_id':'expiry','enabled':False});item(self.db,'later')
        self.assertEqual(run_model(self.db,date(2026,11,20)),0)

if __name__=='__main__':unittest.main()
