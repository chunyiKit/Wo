"""旅行路由/UI源码边界检查；不运行Dart/SDK，不证明平台编译或模型互通。"""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
class LocalTravelContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.route=(ROOT/'lib/local/plugins/travel_routes.dart').read_text()
        cls.ui=(ROOT/'lib/features/plugins/travel/local_travel_add_page.dart').read_text()
    def test_media_schema_contains_only_descriptors(self):
        schema=self.route.split("'plugins/travel/media':",1)[1].split('},',1)[0]
        for name in ('trip_id','kind','thumbnail_sha256','thumbnail_bytes','created_by','sort_key'):
            self.assertIn(name,schema)
        for name in ('locator','source_exact','original_bytes','api_key','file_path'):
            self.assertNotIn(name,schema)
        self.assertIn("'plugins/travel/artifacts':{'trip_id','kind','created_by','created_at','thumbnail_ready'}",self.route)
    def test_restricted_link_is_rejected_before_binding_or_persistence(self):
        create=self.route.split('Future<Json> _create(',1)[1].split('Future<Json> _bindOriginal',1)[0]
        check=create.index("memories.referenceForSpace(fid,values['memory_id'] as String,fid)==null")
        self.assertLess(check,create.index('await _bindOriginal'))
        self.assertLess(check,create.index('await store.batch('))
        self.assertIn("meta['memory_id']!=null",self.route)
        self.assertIn("meta['scope']!=fid||meta['plugin']!='travel'||meta['trip_id']!=tripId",self.route)
    def test_created_trip_never_implicitly_generates(self):
        create=self.route.split('Future<Json> _create(',1)[1].split('Future<Json> _bindOriginal',1)[0]
        self.assertIn("'ai_status':'none'",create)
        self.assertNotIn('client.generate(',create)
        self.assertNotIn('planGeneration(',create)
        self.assertIn("'travel-create:$fid:$id':fingerprint",create)
    def test_model_uses_only_local_referenced_metadata_free_thumbnail(self):
        prepare=self.route.split('Future<PreparedModelImage> _prepared(',1)[1].split('Future<TravelGenerationPlan>',1)[0]
        self.assertIn('await store.deviceReference(id)',prepare)
        self.assertIn("meta['scope']!=fid||meta['trip_id']!=row['id']||meta['plugin']!='travel'",prepare)
        self.assertIn('PreparedModelImage(bytes)',prepare)
        for forbidden in ('native.read(', 'prepareOriginal(', 'file.readAsBytes(', 'http.'):
            self.assertNotIn(forbidden,prepare)
    def test_every_generation_requires_fresh_bound_typed_consent(self):
        generate=self.route.split('Future<Json> generate(',1)[1].split('Future<void> _recordFailure',1)[0]
        for check in ('plan._used','plan.familyId!=fid','plan.tripId!=tripId','plan.fingerprint!=_fingerprint(row)',
                      '!consent.allowSourceUpload','!consent.providerPolicyReviewed','consent.endpoint!=plan.endpoint',
                      'consent.retentionNotice!=plan.retentionNotice','consent.expectedModel!=plan.modelLabel','currentConfig.model!=plan.modelLabel','const Duration(minutes:10)'):
            self.assertIn(check,generate)
        self.assertLess(generate.index('plan._used=true'),generate.index('await client.generate('))
        self.assertIn('required TravelGenerationPlan plan,required ImageGenerationConsent consent',generate)
    def test_artifacts_and_originals_are_retained_and_scope_bound(self):
        self.assertIn('final artifact=await _storeArtifact(fid,tripId,result,plan:plan,attempt:attempt)',self.route)
        self.assertIn("'family_id':fid,'trip_id':tripId,'ext':ext",self.route)
        self.assertIn("raw['family_id']!=fid||raw['trip_id']!=row['trip_id']",self.route)
        self.assertIn("artifact['family_id']!=fid||artifact['trip_id']!=tripId",self.route)
        self.assertNotIn('media.native.release(',self.route)
        self.assertNotIn('media.detach(',self.route)
        self.assertIn("'preview_unavailable'",self.route)
    def test_generated_backup_hashes_and_streams_the_owned_file(self):
        backup=self.route.split('Future<BackupSource> generatedBackupSource',1)[1].split('static Future<Uint8List>',1)[0]
        self.assertIn('hashing.sha256.bind(file.openRead())',backup)
        self.assertNotIn('readAsBytes()',backup)
        self.assertIn('return file!.openRead(offset,offset+length)',self.route)
    def test_local_creation_and_generation_ui_are_separate(self):
        legacy=(ROOT/'lib/features/plugins/travel/travel_add_page.dart').read_text()
        self.assertIn('if (_session.api.isLocal) return const LocalTravelAddPage()',legacy)
        self.assertIn("runtime.media.pick('photo',source:source)",self.ui)
        self.assertIn('var upload=false,reviewed=false',self.ui)
        self.assertIn('upload&&reviewed?',self.ui)
        self.assertIn('Image.memory(plan.image.bytes',self.ui)
        self.assertIn('plan.retentionNotice',self.ui)
        self.assertIn('plan.prompt',self.ui)
        self.assertNotIn('apiKey',self.ui)
    def test_map_gallery_and_picker_have_local_thumbnail_paths(self):
        for name in ('travel_map.dart','travel_city_page.dart'):
            source=(ROOT/'lib/features/plugins/travel'/name).read_text()
            self.assertIn('api.isLocal',source)
            self.assertIn('LocalTravelThumbnail(',source)
        picker=(ROOT/'lib/features/plugins/travel/memory_link_sheet.dart').read_text()
        self.assertIn("list.where((m)=>m.visibility=='family')",picker)
        self.assertIn('LocalMemoryThumbnail(',picker)
        helper=(ROOT/'lib/features/plugins/travel/local_travel_media.dart').read_text()
        self.assertIn('snapshot.connectionState!=ConnectionState.done',helper)
        self.assertIn('gaplessPlayback:false',helper)
        self.assertIn('Image.file(',helper)
    def test_interrupted_generation_never_automatically_resends(self):
        recover=self.route.split('Future<void> recoverInterrupted(',1)[1].split('Future<({String id',1)[0]
        self.assertIn("'generation_error':'interrupted'",recover)
        self.assertIn('travel-inflight:',recover)
        self.assertNotIn('client.generate(',recover)
        self.assertNotIn('planGeneration(',recover)
if __name__=='__main__': unittest.main()
