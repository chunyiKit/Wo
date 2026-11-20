"""旅行同步扩展源码契约；纯Python，不执行Dart/SDK/原生/模型。"""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
class TravelSyncAdapterContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.source=(ROOT/'lib/local/sync/travel_sync_adapter.dart').read_text()
    def test_shadow_lookup_preserves_deleted_history(self):
        self.assertIn('typedef TravelDocumentLookup=Future<Json?> Function(String scope,String collection,String id)',self.source)
        self.assertIn("'_deleted':row['deleted']==1",self.source)
        self.assertIn('required TravelDocumentLookup lookup,Json? previous',self.source)
        self.assertIn('final finalRow=await lookup(scope,collection,id)',self.source)
    def test_family_only_and_strict_fields(self):
        self.assertIn("scope.startsWith('p_')||scope.startsWith('c_')",self.source)
        self.assertIn("TravelRoutes.syncFields['plugins/travel/$kind']",self.source)
        self.assertIn('validBackupId(value)',self.source)
        self.assertIn('m.end==value.length',self.source)
        self.assertIn("changes['created_by']!=actor",self.source)
    def test_memory_projection_uses_only_family_physical_document(self):
        body=self.source.split('Future<bool> _memoryReference(',1)[1].split('Future<void> validateOp',1)[0]
        self.assertIn("'/families/$scope/plugins/memory/memories'",body)
        self.assertIn("memory['visibility']=='family'",body)
        self.assertNotIn('visibleSpaces(',body)
    def test_local_binding_precedes_prepare(self):
        binding=self.source.split('Future<void> _binding(',1)[1].split('Future<Json?> _parent',1)[0]
        for term in ("raw['scope']!=scope", "raw['trip_id']!=tripId", "raw['plugin']!='travel'", "raw['memory_id']!=null", "item['space']!=scope"):
            self.assertIn(term,binding)
        backup=self.source.split('Future<List<BackupSource>> backupSources(',1)[1]
        self.assertLess(backup.index('await _binding(scope,id,'),backup.index('routes.media.prepareBackupSource('))
        self.assertIn("member['status']!='active'",backup)
    def test_orphans_inert_and_thumbnails_require_live_parent_and_reference(self):
        self.assertIn("if(trip==null||trip['_deleted']==true)return;",self.source)
        desc=self.source.split('Future<Json?> _descriptor(',1)[1].split('Future<List<Json>> descriptions',1)[0]
        self.assertIn("row['_deleted']==true",desc)
        self.assertIn("trip['_deleted']==true",desc)
        self.assertIn("artifact['_deleted']==true",desc)
        self.assertIn("artifact['thumbnail_ready']!=true",desc)
    def test_empty_parent_tombstone_is_inert_before_shape_validation(self):
        parent=self.source.split('Future<Json?> _parent(',1)[1].split('Future<bool> _memoryReference',1)[0]
        self.assertIn("if(trip['_deleted']==true)return {'id':tripId,'_deleted':true}",parent)
        self.assertLess(parent.index("if(trip['_deleted']==true)"),parent.index("_required('trips',trip)"))
        operations=self.source.split('Future<void> validateOp(',1)[1].split('Future<Json?> _descriptor',1)[0]
        self.assertLess(operations.index('await _binding(scope,id,tripId)'),operations.index('await _parent(scope,tripId,lookup)'))

    def test_thumbnail_wire_no_original_or_backup_sources(self):
        wire=self.source.split('Future<Json?> thumbnailForWire(',1)[1].split('static String thumbnailBackupId',1)[0]
        self.assertIn('routes.thumbnailForWire(scope,id)',wire)
        self.assertIn("{'space','id','sha256','bytes'}",wire)
        for forbidden in ('prepareBackupSource(', 'generatedBackupSource(', 'native.read(', 'prepareOriginal('):
            self.assertNotIn(forbidden,wire)
        self.assertIn('LocalMediaRepository.validateThumbnail(bytes)',self.source)
    def test_backup_enumerates_every_artifact_and_declares_missing(self):
        backup=self.source.split('Future<List<BackupSource>> backupSources(',1)[1].split('class _TravelMissingSource',1)[0]
        self.assertIn("store.list(scope,_col(scope,'artifacts'))",backup)
        self.assertIn("active.contains(artifact['trip_id'])",backup)
        self.assertIn('routes.generatedBackupSource(scope,id,privacy:privacy)',backup)
        self.assertIn('_TravelMissingSource',backup)
        self.assertNotIn("trip['generated_media_id']",backup)
        self.assertIn("missing:'source_unavailable'",self.source)
    def test_generated_thumb_id_is_fixed_length_and_scope_bound(self):
        self.assertIn("hash(utf8.encode('$scope|$id')).substring(0,48)",self.source)
        self.assertIn("'thumb_${",self.source)
        self.assertIn('if(!seen.add(source.entry.id))_bad()',self.source)
if __name__=='__main__': unittest.main()
