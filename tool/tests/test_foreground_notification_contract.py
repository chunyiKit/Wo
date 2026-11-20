"""前台消息静态契约及独立SQLite/请求顺序模型；不执行Dart/SDK/系统通知。"""
from pathlib import Path
import asyncio
import json
import re
import sqlite3
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
API = (ROOT / 'lib/local/local_api.dart').read_text()
RUNTIME = (ROOT / 'lib/local/local_runtime.dart').read_text()
DUE = (ROOT / 'lib/local/local_foreground_reminders.dart').read_text()
SESSION = (ROOT / 'lib/data/wo_session.dart').read_text()
PAGE = (ROOT / 'lib/features/messages/messages_page.dart').read_text()
FINANCE = (ROOT / 'lib/local/plugins/retirement_subscription.dart').read_text()
SQL = re.search(r"tx.rawInsert\('([^']+)'", API).group(1)


def mark(db, ids, stamp):
    # 独立模型采用源码中的实际写SQL；只证明SQLite事务/持久化语义。
    count = 0
    with db:
        for identity in ids:
            key = f'private:notification-read:family:{identity}'
            row = db.execute('SELECT value FROM meta WHERE key=?', [key]).fetchone()
            old = None if row is None else json.loads(row[0])
            if old is True or isinstance(old, str):
                continue
            db.execute(SQL, [key, json.dumps(stamp)])
            count += 1
    return count


class SourceContract(unittest.TestCase):
    def test_transport_and_local_due_have_independent_futures(self):
        source = RUNTIME.split('Future<void> foreground(bool active)', 1)[1].split('static Future<LocalRuntime> _open', 1)[0]
        self.assertIn('final transport=()async{try{await sync.start();}catch(_){}}();', source)
        self.assertIn('await Future.wait<void>([transport,_reminderPass])', source)
        self.assertIn('isActive:()=>epoch==_foregroundEpoch', source)
        self.assertIn('await sync.stop()', source)
        self.assertIn('try{await api.initialize();}finally{changed();}', RUNTIME)

    def test_enabled_checks_and_per_plugin_failure_isolation(self):
        for plugin in ('anniversary', 'calendar', 'plant', 'retirement', 'subscription', 'pet'):
            self.assertIn("'" + plugin + "'", DUE)
        loop = DUE.split('for (final entry in _plugins.entries)', 1)[1]
        self.assertIn("row['enabled'] == true", loop)
        self.assertLess(loop.index('try {'), loop.index('await process(fid)'))
        self.assertIn('catch (_)', loop)
        self.assertIn('return await _revision() != before', DUE)

    def test_subscription_gate_inside_same_financial_transaction(self):
        source = FINANCE.split('Future<int> _subscriptionDue(', 1)[1].split('class _FinancialEvents', 1)[0]
        gate = "if (!await _installed(tx, fid, 'subscription', enabled: true)) return <Json>[];"
        self.assertLess(source.index('store.batchComputed((tx) async'), source.index(gate))
        self.assertLess(source.index(gate), source.index('final raw ='))
        self.assertIn("stable('subscription-charge:$fid:$sourceId:$due')", source)
        self.assertIn('advanceDue(due, entry[', source)

    def test_read_at_is_persisted_not_get_time_and_legacy_bool_survives(self):
        source = API.split('Future<List<Json>> _notifications()', 1)[1].split('Future<List<Json>> _installedList', 1)[0]
        self.assertIn("'read_at':readAt", source)
        self.assertNotIn('==true?_stamp', source)
        self.assertIn('marker==true||readAt!=null', source)
        self.assertIn('store.db.transaction((tx)async', source)
        self.assertIn('if(marker==true||_notificationReadAt(marker)!=null)continue;', source)
        self.assertIn("result={'marked':await _markNotificationsRead(rows)}", API)
        model = (ROOT / 'lib/data/models.dart').read_text().split('class WoNotification', 1)[1].split('class InvitationResult', 1)[0]
        self.assertIn("read: j['is_read'] == true", model)
        self.assertIn('bool get isRead => read || readAt != null', model)

    def test_recipients_fail_closed_and_local_flags_not_business_operations(self):
        self.assertIn('recipients is! List', API)
        self.assertIn('recipients.any((id)=>id is! String || id.isEmpty)', API)
        self.assertIn('!recipients.contains(store.deviceId)', API)
        source = API.split('Future<int> _markNotificationsRead', 1)[1].split('Future<List<Json>> _installedList', 1)[0]
        self.assertNotIn('store.patch(', source)
        self.assertIn('private:notification-read:', source)
        self.assertIn('notification-hidden:', source)

    def test_page_and_badge_latest_request_wins_preserving_cached_list(self):
        load = SESSION.split('Future<void> load()', 1)[1].split('Future<void> refresh()', 1)[0]
        self.assertEqual(load.count('request != _loadRequest'), 2)
        self.assertIn('request == _loadRequest', load)
        page = PAGE.split('Future<void> _firstLoad()', 1)[1].split('Future<void> _markRead', 1)[0]
        self.assertEqual(page.count('final request = ++_request;'), 2)
        self.assertGreaterEqual(page.count('request == _request'), 5)
        self.assertNotIn('_items = null', page)
        self.assertIn('messagesRefreshSignal.addListener(_onRefreshSignal)', PAGE)
        self.assertIn('messagesRefreshSignal.removeListener(_onRefreshSignal)', PAGE)
        self.assertIn('_request++; // 使删除前', PAGE)


class SqliteAndIndependentModels(unittest.TestCase):
    def test_foreground_tick_stops_in_background_and_does_not_repeat_billing(self):
        self.assertIn('Timer.periodic(const Duration(minutes:1)', RUNTIME)
        self.assertIn('_foregroundReminderTimer?.cancel()', RUNTIME)
        self.assertIn('epoch!=_foregroundEpoch||_reminderJobs>0', RUNTIME)
        self.assertIn('includeFinance=day!=financeDay', RUNTIME)
        self.assertIn("entry.key=='finance'&&!includeFinance", DUE)
        # 独立日历触发模型；不执行Dart Timer，不声称后台唤醒。
        last = '2026-11-20'
        calls = []
        for day, active, busy in [('2026-11-20', True, False), ('2026-11-21', True, True),
                                  ('2026-11-21', False, False), ('2026-11-21', True, False),
                                  ('2026-11-21', True, False)]:
            if not active or busy:
                continue
            financial = day != last
            if financial:
                last = day
            calls.append(financial)
        self.assertEqual(calls, [False, True, False])

    def test_real_sqlite_all_read_rollback_and_restart_stable_timestamp(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'local.sqlite'
            db = sqlite3.connect(path)
            db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)')
            db.execute("CREATE TRIGGER reject_b BEFORE INSERT ON meta WHEN NEW.key='private:notification-read:family:b' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
            with self.assertRaises(sqlite3.IntegrityError):
                mark(db, ['a', 'b'], '2026-11-20T12:00:00Z')
            self.assertEqual(db.execute('SELECT * FROM meta').fetchall(), [])
            db.execute('DROP TRIGGER reject_b')
            self.assertEqual(mark(db, ['a', 'b'], '2026-11-20T12:00:00Z'), 2)
            db.close()
            db = sqlite3.connect(path)
            self.assertEqual(mark(db, ['a', 'b'], '2026-11-22T15:00:00Z'), 0)
            self.assertEqual({json.loads(row[0]) for row in db.execute('SELECT value FROM meta')}, {'2026-11-20T12:00:00Z'})
            db.close()

    def test_real_sqlite_legacy_boolean_read_has_no_invented_time(self):
        db = sqlite3.connect(':memory:')
        db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)')
        db.execute(SQL, ['private:notification-read:family:legacy', 'true'])
        db.commit()
        self.assertEqual(mark(db, ['legacy'], '2026-11-20T12:00:00Z'), 0)
        self.assertEqual(db.execute('SELECT value FROM meta').fetchone()[0], 'true')
        db.close()

    def test_deterministic_occurrence_dedup_survives_read_and_hide_model(self):
        docs, hidden, reads = {}, set(), set()
        identity = str(uuid.uuid5(uuid.NAMESPACE_URL, 'calendar:family:event:2026-11-20'))
        def due():
            if identity in docs:
                return 0
            docs[identity] = {'status': 'pending_local_delivery'}
            return 1
        self.assertEqual(due(), 1)
        reads.add(identity); hidden.add(identity)
        self.assertEqual(due(), 0)
        self.assertEqual([i for i in docs if i not in hidden], [])
        self.assertEqual(docs[identity]['status'], 'pending_local_delivery')

    def test_recipient_model_never_falls_back_to_family(self):
        def visible(value):
            return isinstance(value, list) and all(isinstance(i, str) and i for i in value) and 'a' in value
        for malformed in (None, 'a', {'a': True}, ['a', 4], [], ['b']):
            self.assertFalse(visible(malformed))
        self.assertTrue(visible(['a', 'b']))

    def test_latest_request_model_rejects_old_success_error_and_loading(self):
        generation, current, loading = 2, None, True
        def apply(request, result):
            nonlocal current, loading
            if request != generation:
                return
            current, loading = result, False
        apply(1, {'unread': 9}); self.assertTrue(loading); self.assertIsNone(current)
        apply(2, {'unread': 0}); apply(1, {'error': 'old'})
        self.assertEqual(current, {'unread': 0}); self.assertFalse(loading)

    def test_async_transport_failure_does_not_skip_local_due_model(self):
        async def run():
            calls = []
            async def transport():
                try:
                    raise OSError('synthetic unavailable LAN permission')
                except OSError:
                    pass
            async def reminders():
                for plugin in ('anniversary', 'calendar', 'plant'):
                    try:
                        calls.append(plugin)
                        if plugin == 'anniversary':
                            raise ValueError('synthetic invalid date')
                    except ValueError:
                        pass
            await asyncio.gather(transport(), reminders())
            return calls
        self.assertEqual(asyncio.run(run()), ['anniversary', 'calendar', 'plant'])


if __name__ == '__main__':
    unittest.main()
