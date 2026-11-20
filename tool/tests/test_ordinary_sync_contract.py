"""普通附件源码边界与独立SQLite事务模型；不执行Dart、SDK或网络。"""
from pathlib import Path
import json
import sqlite3
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
ADAPTER=(ROOT/'lib/local/sync/ordinary_attachment_sync.dart').read_text()
POLICY=(ROOT/'lib/local/sync/sync_policy.dart').read_text()
STORE=(ROOT/'lib/local/local_store.dart').read_text()
RUNTIME=(ROOT/'lib/local/local_runtime.dart').read_text()
COORD=(ROOT/'lib/local/sync/sync_coordinator.dart').read_text()

class SourceBoundaries(unittest.TestCase):
    def test_runtime_shared_routes_and_backup_adapter(self):
        for text in ('this.chats,this.pets,this.ordinary', 'ordinary:ordinary', 'chats:chats,pets:pets'):
            self.assertIn(text,RUNTIME)
        snapshot=(ROOT/'lib/local/backup/local_backup_snapshot.dart').read_text()
        self.assertIn('ordinary!.backupSources(familyId)',snapshot)
        self.assertIn('BackupPrivacy.restricted',ADAPTER)
        self.assertIn('await _check();yield chunk;',ADAPTER)
        self.assertIn('_MissingOrdinarySource(d.id)',ADAPTER)
    def test_transport_is_capability_negotiated_and_bounded(self):
        self.assertIn("'ordinary_attachments':1",COORD)
        self.assertIn("ordinary!=offer.containsKey('ordinary_attachments')",COORD)
        self.assertIn('round<16',COORD)
        for text in ('requests.length<2', 'examined<64', 'ordinaryAttachmentChunkBytes', '_requested.remove(peer.id)', 'if(await _active(peer.familyId,d.plugin,id)==null)continue;'):
            self.assertIn(text,ADAPTER)
        # 普通附件实现只触及自己的副本仓库；不会读取回忆原件或旅行原件。
        for text in ('media.readOriginal', 'owned.read', 'readOriginal(', 'source_uri', 'original_ref'):
            self.assertNotIn(text,ADAPTER)
    def test_post_merge_guard_runs_before_clock_and_cursor_commit(self):
        merge=STORE.split('Future<int> merge(',1)[1].split('Future<void> _accept',1)[0]
        self.assertLess(merge.index('await _accept'),merge.index('await validateAfterMerge(tx)'))
        self.assertLess(merge.index('await validateAfterMerge(tx)'),merge.index("await _writeMeta(tx, 'clock:$space'"))
        self.assertIn('validateAfterMerge:ordinary==null?null:(tx)=>ordinary!.validateMerged',POLICY)
        self.assertIn('e.value>10',ADAPTER)
        self.assertIn("r['space']!=fid||r['collection']!=collection",ADAPTER)
        self.assertIn('PetRoutes.validateRecordSync',ADAPTER)
        self.assertIn('fields.length!=AttachmentDescriptor.syncFields.length',ADAPTER)
        self.assertIn('actor!=d.authorDeviceId',ADAPTER)
    def test_sqlite_limit_failure_rolls_back_operations_clock_and_files_metadata(self):
        # 两个独立连接依次提交并发分支；超过限额的整批必须回滚且游标不推进。
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'replica.sqlite'
            a=sqlite3.connect(path);b=sqlite3.connect(path)
            try:
                a.executescript('CREATE TABLE attachments(id TEXT PRIMARY KEY,parent TEXT); CREATE TABLE ops(id TEXT PRIMARY KEY); CREATE TABLE meta(key TEXT PRIMARY KEY,value INTEGER); INSERT INTO meta VALUES("clock",9);')
                a.executemany('INSERT INTO attachments VALUES(?,?)',[(str(i),'p') for i in range(9)]);a.commit()
                def merge(db, identity, clock):
                    with db:
                        db.execute('INSERT INTO attachments VALUES(?,?)',[identity,'p'])
                        db.execute('INSERT INTO ops VALUES(?)',[identity])
                        if db.execute('SELECT count(*) FROM attachments WHERE parent=?',['p']).fetchone()[0]>10:
                            raise ValueError('attachment limit')
                        db.execute('UPDATE meta SET value=? WHERE key="clock"',[clock])
                merge(a,'branch-a',10)
                with self.assertRaises(ValueError):merge(b,'branch-b',11)
                self.assertEqual(a.execute('SELECT count(*) FROM attachments').fetchone()[0],10)
                self.assertEqual(a.execute('SELECT id FROM ops').fetchall(),[('branch-a',)])
                self.assertEqual(a.execute('SELECT value FROM meta').fetchone()[0],10)
                self.assertFalse(a.execute('SELECT id FROM attachments WHERE id="branch-b"').fetchall())
                with a:a.execute('DELETE FROM attachments WHERE id="0"')
                merge(b,'branch-b',11)
                self.assertEqual(a.execute('SELECT value FROM meta').fetchone()[0],11)
            finally:a.close();b.close()

if __name__=='__main__':unittest.main()
