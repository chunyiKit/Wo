"""聊天附件的源码接线与独立SQLite故障模型；不执行Dart/Flutter/原生。"""
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]


class ChatAttachmentContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.routes = (ROOT / 'lib/local/plugins/chat_routes.dart').read_text()
        cls.page = (ROOT / 'lib/features/plugins/chat/local_chat_page.dart').read_text()
        cls.descriptor = (ROOT / 'lib/local/attachments/attachment_descriptor.dart').read_text()

    def test_separate_copy_purpose_and_frozen_metadata_without_original_handle(self):
        self.assertIn("'plugins/chat/attachments': AttachmentDescriptor.syncFields", self.routes)
        self.assertIn("'attachment_id'", self.routes)
        self.assertIn("{'chat_image_copy', 'chat_file_copy'}", self.routes)
        self.assertIn('attachmentId: attachmentId(fid, store.deviceId, clientId)', self.routes)
        self.assertIn('await repository.releaseSelection(selected.token)', self.routes)
        self.assertIn('ordinaryAttachmentMaxBytes = 20 * 1024 * 1024', self.descriptor)
        self.assertIn("'source_uri'", (ROOT / 'test/local/chat_routes_test.dart').read_text())
        schema = self.descriptor.split('static const syncFields = ', 1)[1].split(';', 1)[0]
        self.assertNotIn('token', schema)
        self.assertNotIn('uri', schema)
        self.assertNotIn('handle', schema)
        self.assertIn('final Future<OrdinaryAttachmentStore> Function()? attachmentStore;', self.routes)
        text_stage = self.routes.split('Future<Json> stageText(', 1)[1].split('Future<Json?> selectAttachment(', 1)[0]
        self.assertNotIn('_repository()', text_stage)

    def test_transactional_descriptor_and_author_only_remove_wins(self):
        mutation = self.routes.split('await store.batchComputed((tx) async', 1)[1]
        self.assertIn("'collection': col(fid, 'attachments')", mutation)
        self.assertIn("'fields': Map<String, dynamic>.from(descriptor.toJson())..remove('id')", mutation)
        self.assertIn("row['created_by'] != store.deviceId", mutation)
        self.assertIn("'id': row['attachment_id'], 'fields': <String, dynamic>{}, 'delete': true", mutation)
        read = self.routes.split('Future<File?> attachmentFile(', 1)[1].split('Future<List<Json>> _attachmentStates(', 1)[0]
        self.assertEqual(read.count('_readableAttachment(tx, fid, message)'), 2)
        self.assertIn("if (row == null || row['kind'] == 'text')", self.routes)
        retry = self.routes.split('Future<Json> _commitPending(', 1)[1].split('Future<void> discardPending(', 1)[0]
        self.assertIn('await repository.verifiedFile(binding, descriptor.id)', retry)
        self.assertLess(retry.index("if (existing != null)"), retry.index("await repository.verifiedFile"))

    def test_ui_stable_rows_have_separate_local_bytes_status_and_no_old_cloud_send(self):
        self.assertIn('_routes = _runtime!.chats;', self.page)
        self.assertIn('routes.selectAttachment(', self.page)
        self.assertIn('ChatHistoryRefresh<Json>', self.page)
        self.assertIn("itemKey: (message) => ValueKey(message['id'])", self.page)
        self.assertIn('SizedBox(width: 180, height: 180', self.page)
        self.assertIn("oldWidget.message['attachment_status'] != widget.message['attachment_status']", self.page)
        self.assertIn('本机状态不代表其他设备已收到', self.page)
        self.assertIn('暂不支持聊天视频', self.page)
        self.assertIn('尚未接入系统应用打开', self.page)
        self.assertNotIn('uploadFile(', self.page)
        self.assertNotIn('openOriginal(', self.page)

    def test_independent_stable_identity_and_reading_history_update(self):
        def ids(fid, actor, client):
            return (str(uuid.uuid5(uuid.NAMESPACE_URL, f'wo-chat-v1:{fid}:{actor}:{client}')),
                    'a_' + uuid.uuid5(uuid.NAMESPACE_URL, f'wo-chat-attachment-v1:{fid}:{actor}:{client}').hex)
        ident, attachment = ids('family', 'actor', 'client')
        self.assertEqual(ident, 'a693553b-9e00-566b-8525-f7b50d7f99c3')
        self.assertEqual(len(attachment), 34)
        self.assertEqual(len({ids('family','actor','client'), ids('family','other','client'), ids('other','actor','client')}), 3)
        previous = [{'id': 'old', 'attachment_status': 'missing_local'}, {'id': ident, 'local_pending': True}]
        fresh = [{'id': 'backfilled'}, {'id': 'old', 'attachment_status': 'available_local'}, {'id': ident, 'local_pending': False}]
        by_id = {row['id']: row for row in fresh}
        updated = [by_id[row['id']] for row in previous]
        self.assertEqual([row['id'] for row in updated], ['old', ident])
        self.assertEqual(updated[0]['attachment_status'], 'available_local')
        self.assertFalse(updated[1]['local_pending'])

    def test_independent_sqlite_atomic_failure_restart_retry_and_withdraw_gate(self):
        # 独立故障模型证明期望契约；不是在Python重写/运行Dart业务。
        with tempfile.TemporaryDirectory(prefix='wo-chat-attachment-model-') as directory:
            filename = str(Path(directory) / 'model.sqlite')
            db = sqlite3.connect(filename)
            db.executescript('CREATE TABLE drafts(id TEXT PRIMARY KEY,payload TEXT);'
                             'CREATE TABLE messages(id TEXT PRIMARY KEY,author TEXT,attachment TEXT,deleted INT);'
                             'CREATE TABLE descriptors(id TEXT PRIMARY KEY,parent TEXT,deleted INT);'
                             'CREATE TABLE operations(id INTEGER PRIMARY KEY,kind TEXT);')
            db.execute('INSERT INTO drafts VALUES (?,?)', ('stable', json.dumps({'client_id':'stable','kind':'file'})))
            db.executescript("CREATE TRIGGER fail_descriptor BEFORE INSERT ON descriptors BEGIN SELECT RAISE(ABORT,'synthetic'); END;")
            def commit(connection):
                if connection.execute('SELECT id FROM messages WHERE id=?', ('stable',)).fetchone():
                    return
                with connection:
                    connection.execute('DELETE FROM drafts WHERE id=?', ('stable',))
                    connection.execute('INSERT INTO messages VALUES (?,?,?,0)', ('stable','author','asset'))
                    connection.execute('INSERT INTO operations(kind) VALUES (?)', ('message',))
                    connection.execute('INSERT INTO descriptors VALUES (?,?,0)', ('asset','stable'))
                    connection.execute('INSERT INTO operations(kind) VALUES (?)', ('descriptor',))
            with self.assertRaises(sqlite3.IntegrityError): commit(db)
            self.assertEqual(db.execute('SELECT count(*) FROM drafts').fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT count(*) FROM messages').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT count(*) FROM operations').fetchone()[0], 0)
            db.executescript('DROP TRIGGER fail_descriptor;'); db.close()
            db = sqlite3.connect(filename)
            commit(db); commit(db)
            self.assertEqual(db.execute('SELECT count(*) FROM operations').fetchone()[0], 2)
            self.assertEqual(db.execute('SELECT count(*) FROM drafts').fetchone()[0], 0)
            def may_read(actor, active=True):
                return active and bool(db.execute('SELECT 1 FROM messages m JOIN descriptors d ON d.id=m.attachment AND d.parent=m.id WHERE m.id=? AND m.deleted=0 AND d.deleted=0', ('stable',)).fetchone())
            self.assertTrue(may_read('family-member'))
            self.assertFalse(may_read('family-member', active=False))
            def withdraw(actor):
                author = db.execute('SELECT author FROM messages WHERE id=?', ('stable',)).fetchone()[0]
                if author != actor: raise PermissionError('author_only')
                with db:
                    db.execute('UPDATE messages SET deleted=1 WHERE id=?', ('stable',))
                    db.execute('UPDATE descriptors SET deleted=1 WHERE id=?', ('asset',))
            with self.assertRaises(PermissionError): withdraw('other-member')
            self.assertTrue(may_read('family-member'))
            withdraw('author')
            self.assertFalse(may_read('family-member'))
            commit(db)  # 迟到重试不复活墓碑，不再新建消息。
            self.assertFalse(may_read('family-member'))
            db.close()


if __name__ == '__main__':
    unittest.main()
