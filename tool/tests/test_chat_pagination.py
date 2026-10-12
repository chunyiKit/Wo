"""真实 SQLite 分页回归；无需 Flutter / pub get。

DART_BIN=/path/to/dart python3 -m unittest discover -s tool/tests -p 'test_chat_pagination.py' -v
"""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ChatPaginationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(
            [os.environ.get('DART_BIN', 'dart'),
             str(ROOT / 'tool/tests/chat_message_query_test.dart')],
            check=True, capture_output=True, text=True, cwd=ROOT,
        )
        cls.query = json.loads(result.stdout)

    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        # 使用生产建表 SQL，索引和 SQLite 查询语义保持一致。
        source = (ROOT / 'lib/data/chat_local_store.dart').read_text()
        start = source.index('CREATE TABLE chat_messages (')
        end = source.index("\n'''", start)
        self.db.execute(source[start:end])

    def tearDown(self):
        self.db.close()

    def seed(self, count, owner='u1', family='f1', same_time=False, prefix='c'):
        for i in range(count):
            self.db.execute('''INSERT INTO chat_messages
                (client_id,owner_user_id,family_id,sender_name,sender_emoji,
                 kind,status,created_at) VALUES (?,?,?,?,?,?,?,?)''',
                (f'{prefix}{i}', owner, family, '用户', '👤', 'text', 'sent',
                 '2026-06-25T10:00:00.000Z' if same_time else f'{i:010d}'))

    def page(self, kind='latest', cursor=None, limit=500, owner='u1', family='f1'):
        args = [owner, family]
        if cursor:
            args += [cursor[1], cursor[1], cursor[0]]
        sql = ('SELECT local_id, created_at FROM chat_messages WHERE '
               + self.query[kind] + ' ORDER BY ' + self.query['order'])
        if limit is not None:
            sql += ' LIMIT ?'
            args.append(limit)
        return list(reversed(self.db.execute(sql, args).fetchall()))

    def refresh(self, previous, owner='u1', family='f1'):
        first = min(previous, key=lambda row: (row[1], row[0]))
        result = subprocess.run(
            [os.environ.get('DART_BIN', 'dart'),
             str(ROOT / 'tool/tests/chat_message_query_test.dart'),
             json.dumps(dict(owner=owner, family=family, time=first[1],
                             id=first[0], retained=[r[0] for r in previous]))],
            check=True, capture_output=True, text=True, cwd=ROOT)
        query = json.loads(result.stdout)
        return list(reversed(self.db.execute(
            'SELECT local_id, created_at FROM chat_messages WHERE '
            + query['where'] + ' ORDER BY ' + self.query['order'],
            query['args']).fetchall()))

    def test_ack_moves_loaded_message_before_old_boundary(self):
        self.seed(501)
        previous = self.page()
        self.db.execute("UPDATE chat_messages SET created_at = '-000000001' WHERE local_id = 501")
        rows = self.refresh(previous)
        self.assertEqual(rows[0][0], 501)
        self.assertEqual(len(rows), 501)
        self.assertEqual(len({r[0] for r in rows}), 501)

    def test_first_message_ack_moves_earlier(self):
        self.seed(1)
        previous = self.page()
        self.db.execute("UPDATE chat_messages SET created_at = '-000000001' WHERE local_id = 1")
        self.assertEqual(self.refresh(previous), [(1, '-000000001')])

    def test_first_sync_backfills_older_history(self):
        self.seed(1)
        self.db.execute("UPDATE chat_messages SET created_at = '9999999999'")
        previous = self.page()
        self.seed(700, same_time=True, prefix='backfill')
        rows = self.refresh(previous)
        self.assertEqual(rows, previous)
        self.assertEqual(len(self.page('older', rows[0], limit=1)), 1)
        self.assertEqual(len(self.page('older', rows[0], limit=501)), 501)

    def test_forward_reorder_keeps_old_boundary_and_ties(self):
        self.seed(1000, same_time=True)
        previous = self.page()
        self.db.execute("UPDATE chat_messages SET created_at = '9999999999' WHERE local_id = 501")
        rows = self.refresh(previous)
        self.assertEqual(rows[-1][0], 501)
        self.assertEqual({r[0] for r in rows}, {r[0] for r in previous})

    def test_retained_ids_cannot_leak_another_scope(self):
        self.seed(501)
        self.seed(1, owner='u2')
        previous = self.page()
        rows = self.refresh(previous + [(502, '9999999999')])
        self.assertEqual(rows, previous)

    def test_large_retained_set_with_new_insert_and_backfill(self):
        self.seed(5000, same_time=True)
        previous = self.page(limit=4000)
        self.seed(700, same_time=True, prefix='backfill')
        rows = self.refresh(previous)
        self.assertEqual([r[0] for r in rows], list(range(1001, 5701)))

    def test_501_newest_window(self):
        self.seed(501)
        self.assertEqual([r[0] for r in self.page()], list(range(2, 502)))
        self.assertEqual([r[0] for r in self.page('older', self.page()[0])], [1])

    def test_5000_all_pages_with_timestamp_ties(self):
        self.seed(5000, same_time=True)
        fetched = self.page(limit=501)
        has_older = len(fetched) > 500
        page = fetched[1:] if has_older else fetched
        all_rows = page[:]
        pages = 1
        while has_older:
            fetched = self.page('older', page[0], limit=501)
            has_older = len(fetched) > 500
            page = fetched[1:] if has_older else fetched
            all_rows = page + all_rows
            pages += 1
        self.assertEqual(pages, 10)
        self.assertEqual([r[0] for r in all_rows], list(range(1, 5001)))

    def test_empty_exact_page_and_sentinel(self):
        self.assertEqual(self.page(), [])
        self.seed(500)
        page = self.page(limit=501)
        self.assertEqual(len(page), 500)
        self.assertEqual(self.page('older', page[0]), [])

    def test_scope_isolation_in_all_queries(self):
        self.seed(501)
        self.seed(501, owner='u2')
        self.seed(501, family='f2')
        page = self.page()
        self.assertEqual(page[-1][0], 501)
        self.assertEqual(len(self.page('older', page[0])), 1)
        self.assertEqual(len(self.page('window', page[0], limit=None)), 500)
        self.assertEqual(self.page(owner='absent'), [])

    def test_new_messages_do_not_create_history_gaps(self):
        self.seed(5000, same_time=True)
        latest = self.page()
        older = self.page('older', latest[0])
        # 分页后再收到超过一个批次的新消息。
        for i in range(700):
            self.db.execute('''INSERT INTO chat_messages
                (client_id,owner_user_id,family_id,sender_name,sender_emoji,
                 kind,status,created_at) VALUES (?,?,?,?,?,?,?,?)''',
                (f'new{i}', 'u1', 'f1', '用户', '👤', 'text', 'sent',
                 '2026-06-25T10:00:00.000Z'))
        refreshed = self.page('window', older[0], limit=None)
        self.assertEqual([r[0] for r in refreshed], list(range(4001, 5701)))
        self.assertEqual(self.page('older', older[0])[-1][0], 4000)


if __name__ == '__main__':
    unittest.main()
