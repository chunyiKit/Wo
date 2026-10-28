"""使用标准库 SQLite 验证应用中实际 v1→v2 SQL；无需下载 Flutter 依赖。"""
import pathlib
import re
import sqlite3
import unittest

SOURCE = (pathlib.Path(__file__).parents[1] / 'lib/data/chat_local_store.dart').read_text()
SCHEMA = re.search(r"CREATE TABLE chat_messages \(.*?\n\)", SOURCE, re.S).group()
INDEX = re.search(r"CREATE INDEX ix_chat_messages_owner_family_created\n[^']+", SOURCE).group().strip()
COPY = re.search(r"INSERT INTO chat_messages \(local_id.*?FROM chat_messages_v1", SOURCE, re.S).group()


class MigrationTest(unittest.TestCase):
    def test_anonymization_preserves_history_and_isolates_owner_and_family(self):
        # 执行 App 实际更新条件，覆盖不同账号/家庭、活跃成员与未发送消息。
        method = SOURCE.split('Future<void> anonymizeFormerSenders(', 1)[1].split(
            'Future<ChatSyncState>', 1
        )[0]
        where = method.split('where:', 1)[1].split('whereArgs:', 1)[0]
        where = ''.join(re.findall(r"'([^']*)'", where)).replace('$placeholders', '?,?')
        db = sqlite3.connect(':memory:')
        db.execute(SCHEMA)
        for i, owner, family, sender, server in [
            (1, 'u1', 'f1', 'gone', 'm1'),
            (2, 'u1', 'f1', 'u3', 'm2'),
            (3, 'u2', 'f1', 'gone', 'm3'),
            (4, 'u1', 'f2', 'gone', 'm4'),
            (5, 'u1', 'f1', 'gone', None),
        ]:
            db.execute('''INSERT INTO chat_messages
                (local_id,server_id,client_id,owner_user_id,family_id,sender_id,
                 sender_name,sender_emoji,sender_avatar_url,kind,body,status,created_at,image_local_path)
                VALUES (?,?,?, ?,?,?, '原昵称','🙂','/old-avatar','image','原正文','sent','2020-01-01','/photo')''',
                (i, server, f'c{i}', owner, family, sender))
        db.execute(
            f"UPDATE chat_messages SET sender_name=?,sender_emoji=?,sender_avatar_url=NULL WHERE {where}",
            ['匿名用户', '👤', 'u1', 'f1', 'u1', 'u3', '匿名用户', '👤'],
        )
        rows = db.execute('SELECT sender_name,sender_avatar_url,body,image_local_path,sender_id FROM chat_messages ORDER BY local_id').fetchall()
        self.assertEqual(rows[0], ('匿名用户', None, '原正文', '/photo', 'gone'))
        self.assertEqual([row[0] for row in rows[1:]], ['原昵称'] * 4)
        self.assertEqual(db.execute('SELECT count(*) FROM chat_messages').fetchone()[0], 5)

    def test_upgrade_preserves_history_cursor_and_isolates_accounts(self):
        db = sqlite3.connect(':memory:')
        old = SCHEMA.replace('  server_id TEXT,', '  server_id TEXT UNIQUE,')
        old = re.sub(r'  image_retry_\w+ INTEGER NOT NULL DEFAULT 0,\n', '', old)
        old = old.replace('  UNIQUE(owner_user_id, family_id, server_id),\n', '')
        db.execute(old)
        db.execute(INDEX)
        db.execute('CREATE TABLE chat_sync_state (owner_user_id TEXT, family_id TEXT, after_id TEXT)')
        db.execute("INSERT INTO chat_sync_state VALUES ('u1','f1','m1')")
        db.execute("""INSERT INTO chat_messages
          (local_id,server_id,client_id,owner_user_id,family_id,sender_name,sender_emoji,kind,status,created_at,image_remote_url)
          VALUES (42,'m1','c1','u1','f1','妈妈','👩','image','sent','2026-10-01','/image')""")
        with db:
            db.execute('ALTER TABLE chat_messages RENAME TO chat_messages_v1')
            db.execute('DROP INDEX ix_chat_messages_owner_family_created')
            db.execute(SCHEMA)
            db.execute(INDEX)
            db.execute(COPY)
            db.execute('DROP TABLE chat_messages_v1')
        self.assertEqual(db.execute('SELECT local_id,image_retry_attempts,image_retry_at FROM chat_messages').fetchone(), (42, 0, 0))
        self.assertEqual(db.execute('SELECT after_id FROM chat_sync_state').fetchone(), ('m1',))
        # 相同服务端消息可由第二个账号独立缓存，且旧记录仍可补图。
        db.execute("""INSERT INTO chat_messages
          (server_id,client_id,owner_user_id,family_id,sender_name,sender_emoji,kind,status,created_at,image_remote_url)
          SELECT server_id,client_id,'u2',family_id,sender_name,sender_emoji,kind,status,created_at,image_remote_url FROM chat_messages WHERE local_id=42""")
        db.execute("UPDATE chat_messages SET image_local_path='/u1/image.png' WHERE owner_user_id='u1' AND family_id='f1' AND server_id='m1'")
        self.assertEqual(db.execute("SELECT image_local_path FROM chat_messages WHERE owner_user_id='u2'").fetchone(), (None,))
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("""INSERT INTO chat_messages
              (server_id,client_id,owner_user_id,family_id,sender_name,sender_emoji,kind,status,created_at)
              VALUES ('m1','c2','u1','f1','妈妈','👩','image','sent','2026-10-01')""")


if __name__ == '__main__':
    unittest.main()
