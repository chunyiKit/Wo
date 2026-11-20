"""普通附件源码契约及独立真实SQLite/磁盘续传模型；不执行Dart/native/SDK。"""
from pathlib import Path
import base64
import hashlib
import json
import re
import sqlite3
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
SOURCE=(ROOT/'lib/local/attachments/ordinary_attachment_store.dart').read_text()
DESCRIPTOR=(ROOT/'lib/local/attachments/attachment_descriptor.dart').read_text()
CAP=20*1024*1024
CHUNK=256*1024

class Receiver:
    """独立模型，使用源码CREATE TABLE语句；只证明磁盘/SQL/摘要算法，不代表Dart执行。"""
    def __init__(self, root):
        self.root=Path(root)
        self.db=sqlite3.connect(self.root/'attachments.sqlite')
        sql=re.search(r"db.execute\('(CREATE TABLE attachments [^']+)'\)",SOURCE).group(1)
        if not self.db.execute("SELECT name FROM sqlite_master WHERE name='attachments'").fetchone():
            self.db.execute(sql)
    def begin(self, desc):
        serialized=json.dumps(desc,sort_keys=True)
        row=self.db.execute('SELECT descriptor FROM attachments WHERE id=?',[desc['id']]).fetchone()
        if row:
            if row[0]!=serialized:
                raise ValueError('binding conflict')
            return
        key='object-'+desc['id']
        with open(self.root/key,'xb'):
            pass
        with self.db:
            self.db.execute('INSERT INTO attachments VALUES(?,?,?,?,?,?,?,?,?,?)',
                [desc['id'],desc['family_id'],desc['plugin'],desc['parent_id'],desc['author_device_id'],serialized,key,'receiving',0,''])
    def chunk(self, desc, offset, data, crash_after_flush=False):
        row=self.db.execute('SELECT descriptor,object_key,status,received_size FROM attachments WHERE id=?',[desc['id']]).fetchone()
        if row[0]!=json.dumps(desc,sort_keys=True):
            raise ValueError('binding conflict')
        path=self.root/row[1]
        if not 0<len(data)<=CHUNK or offset+len(data)>desc['size']:
            raise ValueError('chunk limit')
        if offset<row[3]:
            if offset+len(data)>row[3] or path.read_bytes()[offset:offset+len(data)]!=data:
                raise ValueError('duplicate conflict')
            return row[3]
        if offset!=row[3] or row[2]!='receiving':
            raise ValueError('offset gap')
        length=path.stat().st_size
        overlap=length-offset
        if overlap<0 or overlap>len(data) or path.read_bytes()[offset:length]!=data[:overlap]:
            raise ValueError('tail conflict')
        with open(path,'ab') as out:
            out.write(data[overlap:]);out.flush()
        if crash_after_flush:
            return row[3]
        following=offset+len(data)
        if following==desc['size'] and hashlib.sha256(path.read_bytes()).hexdigest()!=desc['sha256']:
            with self.db:
                self.db.execute("UPDATE attachments SET status='corrupt' WHERE id=?",[desc['id']])
            raise ValueError('full sha')
        with self.db:
            self.db.execute('UPDATE attachments SET status=?,received_size=? WHERE id=?',
                ['ready' if following==desc['size'] else 'receiving',following,desc['id']])
        return following
    def close(self):
        self.db.close()

def desc(data):
    return dict(id='a_11111111111111111111111111111111',family_id='family-a',plugin='chat',parent_id='message-a',author_device_id='author-a',purpose='chat_file_copy',kind='file',display_name='合成.pdf',content_type='application/pdf',size=len(data),sha256=hashlib.sha256(data).hexdigest(),created_at='2026-11-20T00:00:00Z')

class SourceContract(unittest.TestCase):
    def test_only_four_explicit_purposes_and_bounded_native_copy(self):
        for purpose in ('chat_image_copy','chat_file_copy','pet_image_copy','pet_file_copy'):
            self.assertIn(purpose,DESCRIPTOR)
        self.assertIn('20 * 1024 * 1024',DESCRIPTOR)
        self.assertIn('256 * 1024',DESCRIPTOR)
        self.assertIn("MethodChannel('wo.local/attachments')",SOURCE)
        self.assertIn("'claim',{'token':token,'purpose':purpose}",SOURCE)
        self.assertIn('finally{try{await native.release(selectionToken);}',SOURCE)
    def test_fixed_trusted_root_independent_index_no_media_import_capability(self):
        self.assertIn("privateDirectoryName='ordinary-attachments-v1'",SOURCE)
        self.assertIn('trusted.privateDirectory(privateDirectoryName)',SOURCE)
        self.assertIn('CREATE TABLE attachments ',SOURCE)
        for forbidden in ('local_media_repository','owned_media_store','NativeMedia','PortableRestore','importBytes','sourceUri','locator','open_filex'):
            self.assertNotIn(forbidden,SOURCE)
        signature=SOURCE.split('importSelection({',1)[1].split('})=>',1)[0]
        self.assertNotIn('File',signature)
        self.assertNotIn('Directory',signature)
    def test_display_name_never_forms_file_path(self):
        method=SOURCE.split('File _file(',1)[1].split('Future<String> _random',1)[0]
        self.assertIn('objectKey',method)
        self.assertNotIn('displayName',method)
        self.assertIn('safeAttachmentDisplayName(m.displayName)',SOURCE)
        self.assertIn('r >= 0x202a && r <= 0x202e',DESCRIPTOR)
    def test_binding_is_global_and_immutable(self):
        self.assertIn('id TEXT PRIMARY KEY',SOURCE)
        self.assertIn('old.descriptor.same(descriptor)',SOURCE)
        self.assertIn('asset.descriptor.same(descriptor)',SOURCE)
        self.assertIn('_binding(binding,value.descriptor)',SOURCE)
        for key in ('family_id','plugin','parent_id','author_device_id'):
            self.assertIn(key,DESCRIPTOR)
        self.assertIn("where:'id=?'",SOURCE)
    def test_ready_only_after_full_sha_and_type_check(self):
        self.assertIn('hashes.sha256.bind(file.openRead()).first',SOURCE)
        receive=SOURCE.split('receiveChunk(',1)[1].split('static Future<bool> _sameBytes',1)[0]
        self.assertLess(receive.index('await _verify('),receive.index("'status':next==descriptor.size?'ready'"))
        self.assertIn('validateAttachmentImage(await file.readAsBytes())',SOURCE)
        self.assertIn('validateOrdinaryFileHeader(await input.read(64))',SOURCE)
        self.assertIn('w>1600||h>1600',DESCRIPTOR)
        self.assertIn('marker>=225&&marker<=239||marker==254',DESCRIPTOR)
        for magic in ('255,216','137,80,78,71','102,116,121,112'):
            self.assertIn(magic,DESCRIPTOR)
    def test_exclusive_create_and_resume_never_overwrite_tail(self):
        self.assertGreaterEqual(SOURCE.count('create(exclusive:true)'),4)
        self.assertIn('FileMode.writeOnlyAppend',SOURCE)
        self.assertNotIn('.rename(',SOURCE)
        self.assertNotIn('.truncate(',SOURCE)
        self.assertIn('_sameBytes(file,offset,Uint8List.sublistView(bytes,0,overlap))',SOURCE)
        self.assertIn("'object_key':key,'status':'receiving','received_size':0",SOURCE)
        self.assertIn('attachment_orphans',SOURCE)
    def test_read_frozen_source_and_missing_recheck_binding_and_integrity(self):
        ranged=SOURCE.split('Stream<List<int>> _range(',1)[1].split('Future<void> deleteLocal',1)[0]
        self.assertIn('_required(asset.descriptor.binding,asset.id)',ranged)
        self.assertIn('current.descriptor.same(asset.descriptor)',ranged)
        self.assertIn('await _verify(current)',ranged)
        self.assertIn("kind:'file'",SOURCE)
        self.assertIn('sourceExact:false',SOURCE)
        self.assertEqual(SOURCE.count('BackupPrivacy get privacy=>BackupPrivacy.restricted'),2)
        self.assertIn("missing:'source_unavailable'",SOURCE)
    def test_prepared_native_free_and_no_file_autopreview(self):
        test=(ROOT/'test/local/attachments/ordinary_attachment_store_test.dart').read_text()
        self.assertEqual(test.count("  test('"),13)
        self.assertIn('setMockMethodCallHandler',test)
        self.assertNotIn('open_filex',SOURCE)
        self.assertNotIn('Image.network',SOURCE)

class RealSqliteAndFileModels(unittest.TestCase):
    def test_twenty_mib_real_file_roundtrip_restart_and_exact_sha(self):
        with tempfile.TemporaryDirectory() as folder:
            data=b'%PDF-1.4\n'+b'x'*(CAP-9);d=desc(data);r=Receiver(folder);r.begin(d)
            for offset in range(0,CAP,CHUNK):
                r.chunk(d,offset,data[offset:offset+CHUNK])
                if offset==CHUNK:
                    r.close();r=Receiver(folder);r.begin(d)
            row=r.db.execute('SELECT status,received_size,object_key FROM attachments').fetchone()
            self.assertEqual(row[:2],('ready',CAP))
            self.assertEqual(hashlib.sha256((Path(folder)/row[2]).read_bytes()).hexdigest(),d['sha256']);r.close()
    def test_flush_without_index_offset_retries_identical_tail_only(self):
        with tempfile.TemporaryDirectory() as folder:
            data=b'%PDF-1.4\n'+b'x'*600;d=desc(data);r=Receiver(folder);r.begin(d)
            self.assertEqual(r.chunk(d,0,data[:200],True),0);r.close();r=Receiver(folder)
            with self.assertRaisesRegex(ValueError,'tail conflict'):
                r.chunk(d,0,b'Z'*200)
            self.assertEqual(r.chunk(d,0,data[:200]),200)
            self.assertEqual(r.chunk(d,0,data[:200]),200)
            self.assertEqual(r.chunk(d,200,data[200:]),len(data));r.close()
    def test_wrong_full_digest_never_publishes_ready(self):
        with tempfile.TemporaryDirectory() as folder:
            data=b'%PDF-1.4 synthetic';d=desc(data);r=Receiver(folder);r.begin(d)
            with self.assertRaisesRegex(ValueError,'full sha'):
                r.chunk(d,0,b'Z'*len(data))
            self.assertEqual(r.db.execute('SELECT status FROM attachments').fetchone()[0],'corrupt');r.close()
    def test_sqlite_primary_id_cannot_be_rebound_to_another_scope(self):
        with tempfile.TemporaryDirectory() as folder:
            data=b'synthetic';d=desc(data);r=Receiver(folder);r.begin(d)
            for key in ('family_id','plugin','parent_id','author_device_id','sha256'):
                with self.assertRaisesRegex(ValueError,'binding conflict'):
                    r.begin(dict(d,**{key:'other'}))
            r.close()
    def test_hole_and_chunk_limit_do_not_advance_sql_offset(self):
        with tempfile.TemporaryDirectory() as folder:
            data=b'x'*(CHUNK+2);d=desc(data);r=Receiver(folder);r.begin(d)
            with self.assertRaisesRegex(ValueError,'offset gap'):
                r.chunk(d,1,b'x')
            with self.assertRaisesRegex(ValueError,'chunk limit'):
                r.chunk(d,0,data)
            self.assertEqual(r.db.execute('SELECT received_size FROM attachments').fetchone()[0],0);r.close()
    def test_real_synthetic_jpeg_has_no_metadata_and_safe_dimensions(self):
        from PIL import Image
        from io import BytesIO
        fixture=(ROOT/'test/local/attachments/ordinary_attachment_store_test.dart').read_text()
        encoded=re.search(r"final jpeg=Uint8List.fromList\(base64Decode\('([^']+)'\)\)",fixture).group(1)
        image=Image.open(BytesIO(base64.b64decode(encoded)))
        self.assertEqual(image.size,(1,1));self.assertEqual(dict(image.getexif()),{})

if __name__=='__main__':
    unittest.main()
