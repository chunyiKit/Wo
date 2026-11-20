"""本地家聊静态边界及独立SQLite/UUID模型；不运行Dart或原生，不等于手机实测。"""
import json
from pathlib import Path
import re
import sqlite3
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]

class LocalChatContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.routes = (ROOT / 'lib/local/plugins/chat_routes.dart').read_text()
        cls.page = (ROOT / 'lib/features/plugins/chat/local_chat_page.dart').read_text()
        cls.entry = (ROOT / 'lib/features/plugins/chat/chat_page.dart').read_text()

    def test_transactional_message_identity_and_retry_contract(self):
        self.assertIn("uuid.v5(namespace, 'wo-chat-v1:$fid:$actor:$client')", self.routes)
        self.assertIn('await store.batchComputed((tx) async', self.routes)
        self.assertIn("old['body'] != text", self.routes)
        self.assertIn("old['client_id'] != client", self.routes)
        self.assertIn('return <Json>[]', self.routes)
        self.assertIn("'delivery_status': 'saved_local'", self.routes)
        self.assertNotIn("'delivery_status': 'delivered'", self.routes)
        self.assertIn('match.end == value.length', self.routes)

    def test_tombstones_and_actor_scope_are_not_fake_erase(self):
        self.assertIn("row['created_by'] != store.deviceId", self.routes)
        self.assertIn("'fields': <String, dynamic>{}, 'delete': true", self.routes)
        self.assertIn("'retracted': row['deleted'] == 1", self.routes)
        self.assertIn("'body': retracted ? null : row['body']", self.routes)
        self.assertIn("member['family_id'] != fid", self.routes)
        self.assertIn('既有归档中的内容无法自动收回', self.page)

    def test_local_dispatch_does_not_start_old_sync_or_attachment_queue(self):
        dependencies = self.entry.split('void didChangeDependencies()', 1)[1].split('void dispose()', 1)[0]
        local = dependencies.split('if (session.api.isLocal)', 1)[1].split('if (!identical(_session, session))', 1)[0]
        self.assertIn('return;', local)
        self.assertNotIn('_start(', local)
        self.assertIn('if (WoScope.api(context).isLocal) return const LocalChatPage();', self.entry)
        self.assertNotIn('ChatSyncService', self.page.split('class LocalChatPage', 1)[1])
        self.assertNotIn('uploadFile(', self.page)
        self.assertNotRegex(self.page, r'(?<![A-Za-z0-9_.])File\(')
        self.assertIn('routes.selectAttachment(', self.page)
        self.assertIn('chat_image_copy', self.page)
        self.assertIn('暂不支持聊天视频', self.page)
        self.assertIn('回忆原件不会作为聊天附件发送', self.routes)

    def test_snapshot_and_stable_ids_cover_backfill_and_existing_row_updates(self):
        snapshot = self.routes.split('Future<List<Json>> _snapshot(', 1)[1].split('static int compareMessages(', 1)[0]
        self.assertNotIn('after_created_at', snapshot)
        self.assertNotIn('retention_cutoff', snapshot)
        self.assertIn('result.sort(compareMessages)', snapshot)
        for guard in ('ChatHistoryRefresh<Json>', 'readingHistory: reading', 'refresh.items',
                      "itemKey: (message) => ValueKey(message['id'])", 'runtime!.changes.addListener(_changed)',
                      '_runtime?.changed()', '_knownIds', '_hasOlder = _startIndex(rows, _items) > 0'):
            self.assertIn(guard, self.page)
        self.assertIn('MemberAvatar(url:', self.page)
        self.assertIn('同一操作 ID', (ROOT / 'lib/local/local_store.dart').read_text())

    def test_private_outbox_precedes_commit_and_cannot_restart_a_discarded_draft(self):
        self.assertIn("'private:chat-outbox:$fid:${store.deviceId}'", self.routes)
        self.assertIn('static const maxPending = 100', self.routes)
        self.assertIn('requirePending && staged == null', self.routes)
        self.assertIn('requirePending: true', self.routes)
        self.assertIn('whenComplete(() { _commits.remove(key); })', self.routes)
        commit = self.routes.split('Future<Json> _commitPending(', 1)[1].split('Future<void> discardPending(', 1)[0]
        self.assertLess(commit.index('final existing = await _document('), commit.index("await request('POST'"))
        self.assertIn('includeDeleted: true', commit)
        send = self.page.split('Future<void> _send()', 1)[1].split('Future<void> _retryPending(', 1)[0]
        self.assertLess(send.index('await routes.stageText('), send.index('routes.commitPending('))
        self.assertIn('routes.localSnapshot(family)', self.page)
        self.assertIn('e.statusCode == 403', self.page)
        self.assertIn('_items = []; _statuses = []; _knownIds = null; _text.clear(); _authorized = false;', self.page)
        self.assertIn('本机待发送 · 点按重试', self.page)
        self.assertIn('enabled: _authorized', self.page)

    def test_independent_sqlite_outbox_survives_restart_and_transaction_rollback(self):
        source = (ROOT / 'lib/local/local_store.dart').read_text()
        schemas = [re.search(r"db.execute\('(?P<sql>CREATE TABLE " + table + r" [^']+)'\)", source).group('sql')
                   for table in ('meta', 'documents', 'operations')]
        ident = str(uuid.uuid5(uuid.NAMESPACE_URL, 'wo-chat-v1:family:actor:durable'))
        key = 'private:chat-outbox:family:actor'
        with tempfile.TemporaryDirectory(prefix='wo-chat-oracle-') as directory:
            filename = str(Path(directory) / 'synthetic.sqlite')
            db = sqlite3.connect(filename)
            for schema in schemas:
                db.execute(schema)
            db.execute('INSERT INTO meta VALUES (?,?)', (key, '[{"client_id":"durable","body":"synthetic"}]'))
            db.commit(); db.close()
            db = sqlite3.connect(filename)
            self.assertIsNotNone(db.execute('SELECT value FROM meta WHERE key=?', (key,)).fetchone())
            db.execute("CREATE TRIGGER fail_op BEFORE INSERT ON operations BEGIN SELECT RAISE(ABORT, 'synthetic'); END")
            db.commit()
            with self.assertRaises(sqlite3.IntegrityError):
                with db:
                    db.execute('DELETE FROM meta WHERE key=?', (key,))
                    db.execute('INSERT INTO operations VALUES (?,?,?,?,?)', ('family', 'actor', 1, 1, '{}'))
            self.assertIsNotNone(db.execute('SELECT value FROM meta WHERE key=?', (key,)).fetchone())
            self.assertEqual(db.execute('SELECT count(*) FROM operations').fetchone()[0], 0)
            db.execute('DROP TRIGGER fail_op'); db.commit()
            with db:
                db.execute('DELETE FROM meta WHERE key=?', (key,))
                db.execute('INSERT INTO documents VALUES (?,?,?,?,?,?,?)', ('family', '/families/family/plugins/chat/messages', ident, '{"body":"synthetic"}', '{}', 0, 1))
                db.execute('INSERT INTO operations VALUES (?,?,?,?,?)', ('family', 'actor', 1, 1, '{}'))
            db.close(); db = sqlite3.connect(filename)
            self.assertIsNone(db.execute('SELECT value FROM meta WHERE key=?', (key,)).fetchone())
            self.assertEqual(db.execute('SELECT id FROM documents').fetchall(), [(ident,)])
            self.assertEqual(db.execute('SELECT count(*) FROM operations').fetchone()[0], 1)
            db.close()

    def test_independent_uuid_vector_and_scopes(self):
        def message(family, actor, client):
            return str(uuid.uuid5(uuid.NAMESPACE_URL, f'wo-chat-v1:{family}:{actor}:{client}'))
        self.assertEqual(message('family', 'actor', 'client'), 'a693553b-9e00-566b-8525-f7b50d7f99c3')
        self.assertEqual(len({message('family', 'a', 'same'), message('family', 'b', 'same'),
                              message('other', 'a', 'same')}), 3)

    def test_sqlite_snapshot_model_reads_old_time_and_retracted_placeholder(self):
        source = (ROOT / 'lib/local/local_store.dart').read_text()
        sql = re.search(r"db.execute\('(?P<sql>CREATE TABLE documents [^']+)'\)", source).group('sql')
        db = sqlite3.connect(':memory:')
        try:
            db.execute(sql)
            collection = '/families/family/plugins/chat/messages'
            for ident, when in [('current', '2026-11-20T10:00:00Z'), ('backfill', '1999-01-01T00:00:00Z')]:
                db.execute('INSERT INTO documents VALUES (?,?,?,?,?,?,?)',
                           ('family', collection, ident, json.dumps({'body': ident, 'created_at': when}), '{}', 0, 1))
            db.execute('INSERT INTO documents VALUES (?,?,?,?,?,?,?)',
                       ('other', '/families/other/plugins/chat/messages', 'other', '{"body":"forbidden"}', '{}', 0, 1))
            db.execute('UPDATE documents SET deleted=1 WHERE id=?', ('current',))
            rows = db.execute('SELECT id,data,deleted FROM documents WHERE space=? AND collection=?', ('family', collection)).fetchall()
            result = [dict(json.loads(raw), id=ident, retracted=bool(deleted)) for ident, raw, deleted in rows]
            result.sort(key=lambda row: (row['created_at'], row['id']))
            self.assertEqual([row['id'] for row in result], ['backfill', 'current'])
            visible = [{**row, 'body': None if row['retracted'] else row['body']} for row in result]
            self.assertIsNone(visible[1]['body'])
            self.assertIn('current', next(raw for ident, raw, deleted in rows if ident == 'current'))  # 标记撤回不宣称物理擦除既有历史。
        finally:
            db.close()

    def test_independent_reader_model_keeps_rows_and_replaces_by_stable_id(self):
        previous = [{'id': 'b', 'body': 'old'}, {'id': 'c', 'body': 'old'}]
        fresh = [{'id': 'a', 'body': 'backfill'}, {'id': 'b', 'body': None, 'retracted': True},
                 {'id': 'c', 'body': 'updated'}]
        by_id = {row['id']: row for row in fresh}
        reading = [by_id.get(row['id'], row) for row in previous]
        self.assertEqual([row['id'] for row in reading], ['b', 'c'])
        self.assertTrue(reading[0]['retracted'])
        self.assertEqual(reading[1]['body'], 'updated')
        self.assertIn('a', [row['id'] for row in fresh])

if __name__ == '__main__':
    unittest.main()
