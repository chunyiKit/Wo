"""旅行策略源码契约与独立轮转模型；Python执行不代表Dart/SDK/原生已执行。"""
from pathlib import Path
import math
import unittest

ROOT=Path(__file__).resolve().parents[2]


def model_missing_round(candidates, cursor, is_missing, scan_limit=64, request_limit=16):
    """独立Python规范模型：游标按已检查项推进，不能只从永久缺件列表头重试。"""
    count=len(candidates)
    if not count:
        return [],0,0
    cursor%=count
    requests=[]
    scanned=0
    while scanned<min(scan_limit,count) and len(requests)<request_limit:
        candidate=candidates[(cursor+scanned)%count]
        scanned+=1
        if is_missing(candidate):
            requests.append(candidate)
    return requests,(cursor+scanned)%count,scanned


class MissingThumbnailRotationModelTests(unittest.TestCase):
    def test_model_sixteen_permanent_missing_cannot_starve_later_missing(self):
        candidates=list(range(200))
        missing=set(range(16))|{199}
        cursor=0
        requested=set()
        for _ in range(20):
            batch,cursor,scanned=model_missing_round(candidates,cursor,missing.__contains__)
            self.assertLessEqual(scanned,64)
            self.assertLessEqual(len(batch),16)
            requested.update(batch)
        self.assertIn(199,requested)
        self.assertTrue(set(range(16))<=requested)

    def test_model_all_missing_eventually_visits_every_candidate(self):
        for size in (1,15,16,17,63,64,65,300):
            with self.subTest(size=size):
                candidates=list(range(size))
                cursor=0
                visited=set()
                for _ in range(math.ceil(size/16)+1):
                    batch,cursor,scanned=model_missing_round(candidates,cursor,lambda _:True)
                    self.assertLessEqual(scanned,64)
                    self.assertLessEqual(len(batch),16)
                    visited.update(batch)
                self.assertEqual(visited,set(candidates))

    def test_model_available_stretch_advances_scan_cursor_without_requests(self):
        candidates=list(range(150))
        batch,cursor,scanned=model_missing_round(candidates,0,lambda _:False)
        self.assertEqual(batch,[])
        self.assertEqual((cursor,scanned),(64,64))
        batch,cursor,scanned=model_missing_round(candidates,cursor,lambda item:item==149)
        self.assertEqual(batch,[])
        self.assertEqual(cursor,128)
        batch,cursor,scanned=model_missing_round(candidates,cursor,lambda item:item==149)
        self.assertEqual(batch,[149])
        self.assertEqual(scanned,64)

    def test_model_empty_shrinking_and_growing_lists_keep_bounds(self):
        self.assertEqual(model_missing_round([],999,lambda _:True),([],0,0))
        for size in (2,100,1,17,300,3):
            batch,cursor,scanned=model_missing_round(list(range(size)),99999,lambda _:True)
            self.assertTrue(0<=cursor<size)
            self.assertLessEqual(scanned,min(64,size))
            self.assertEqual(len(batch),min(16,size))

    def test_model_cursor_is_per_consumer_and_never_expands_scope(self):
        authorized_a=['a0','a1']
        authorized_b=['b0']
        a,ac,_=model_missing_round(authorized_a,0,lambda _:True,request_limit=1)
        b,bc,_=model_missing_round(authorized_b,0,lambda _:True,request_limit=1)
        a_next,_,_=model_missing_round(authorized_a,ac,lambda _:True,request_limit=1)
        self.assertEqual((a,b,a_next),(['a0'],['b0'],['a1']))
        self.assertEqual(bc,0)


class TravelPolicySourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy=(ROOT/'lib/local/sync/sync_policy.dart').read_text()
        cls.adapter=(ROOT/'lib/local/sync/travel_sync_adapter.dart').read_text()
        cls.prepared=(ROOT/'test/local/sync/travel_policy_integration_test.dart').read_text()

    def test_travel_is_explicit_extension_and_full_shadow_precedes_merge(self):
        self.assertIn('TravelSyncAdapter? travel',self.policy)
        apply=self.policy.split('Future<void> apply(',2)[-1]
        self.assertIn('final finalView=',apply)
        self.assertIn('Future<Json?> finalLookup(',apply)
        self.assertIn('old?',apply)
        self.assertIn("'_deleted':old?['_deleted']==true||op['kind']=='delete'",apply)
        self.assertLess(apply.index('await travel!.validateOp(op,lookup:finalLookup'),apply.index('await store.merge('))
        self.assertLess(apply.index("_object(op,{'space','actor','sequence','clock','collection','id','kind','fields'})"),apply.index('await travel!.validateOp('))

    def test_same_packet_media_id_cannot_cross_plugin_or_scope(self):
        self.assertIn('mediaBindings=<String,String>{}',self.policy)
        self.assertIn("final binding='$scope|$collection'",self.policy)
        self.assertIn('mediaBindings[id]!=null&&mediaBindings[id]!=binding',self.policy)
        self.assertIn('同批媒体ID跨权限空间或插件',self.policy)
        self.assertIn('await media.verifyMediaOwnership(scope,id,',self.policy)
        self.assertIn('同包memory与travel重复媒体ID必须整包拒绝',self.prepared)
        self.assertIn('同包跨family/couple scope重复媒体ID必须整包拒绝',self.prepared)

    def test_private_and_couple_cannot_become_travel_transport_scopes(self):
        self.assertIn("result.any((s)=>s.startsWith('p_'))",self.policy)
        self.assertIn("scope!=peer.familyId&&!suffix.startsWith('plugins/memory/')",self.policy)
        self.assertIn("scope.startsWith('p_')||scope.startsWith('c_')",self.adapter)
        self.assertIn('p与c空间的旅行即使误列scope候选也拒绝整包',self.prepared)

    def test_inactive_parent_never_produces_travel_thumbnail_install(self):
        descriptor=self.adapter.split('Future<Json?> _descriptor(',1)[1].split('Future<List<Json>> descriptions(',1)[0]
        for guard in ("row['_deleted']==true","trip['_deleted']==true","artifact['_deleted']==true"):
            self.assertIn(guard,descriptor)
        apply=self.policy.split('Future<void> apply(',2)[-1]
        self.assertIn('await travel!.validateThumbnail(',apply)
        self.assertIn('lookup:finalLookup',apply)
        self.assertLess(apply.index('await travel!.validateThumbnail('),apply.index('await store.merge('))
        self.assertIn('孤立travel descriptor可推进日志，但无父thumb绝不安装',self.prepared)
        self.assertIn('先delete后birth空父墓碑保持惰性，旧thumb不复活内容',self.prepared)

    def test_strategy_uses_thumbnail_dispatch_and_never_original_io(self):
        for forbidden in ('prepareOriginal(', 'prepareBackupSource(', 'generatedBackupSource(', 'backupSources(', 'native.read(', '_nativeRange('):
            self.assertNotIn(forbidden,self.policy)
        self.assertIn('travel!.thumbnailForWire(scope,id)',self.policy)
        self.assertIn('travel!.receiveThumbnail(t.scope,t.id,t.bytes,t.hash)',self.policy)
        self.assertIn('LocalMediaRepository.validateThumbnail(bytes)',self.policy)
        self.assertIn('本机源引用不会随出口ops或thumb发送',self.prepared)
        self.assertIn('expect(native.reads,0)',self.prepared)
        self.assertIn('expect(native.prepared,0)',self.prepared)

    def test_state_scan_and_request_budgets_advance_per_peer_cursor(self):
        state=self.policy.split('@override Future<Map<String,dynamic>> state(',1)[1].split('@override Future<Map<String,dynamic>> delta(',1)[0]
        self.assertIn('_missingCursor[peer.id]',state)
        self.assertIn('examined<64&&examined<candidates.length&&missing.length<16',state)
        self.assertIn('examined++;cursor=(cursor+1)%candidates.length',state)
        self.assertIn('_missingCursor[peer.id]=cursor',state)
        self.assertLess(state.index('_missingCursor[peer.id]=cursor'),state.index("return {'t':'state'"))
        self.assertIn('最多64文件探测/16请求',self.prepared)
        self.assertIn('media.fileProbes,lessThanOrEqualTo(64)',self.prepared)

    def test_bad_derived_thumbnail_is_missing_but_binding_errors_stay_fail_closed(self):
        state=self.policy.split('@override Future<Map<String,dynamic>> state(',1)[1].split('@override Future<Map<String,dynamic>> delta(',1)[0]
        self.assertIn('on FileSystemException{absent=true;}on ThumbnailUnavailable{absent=true;}',state)
        self.assertNotIn('on FormatException',state)
        self.assertNotIn('catch(',state)
        route=(ROOT/'lib/local/plugins/travel_routes.dart').read_text()
        thumbnail=route.split('Future<Uint8List?> thumbnailBytes(',1)[1].split('Future<Json?> thumbnailForWire(',1)[0]
        self.assertLess(thumbnail.index('await _localBinding('),thumbnail.index('on FormatException{throw const ThumbnailUnavailable();}'))
        parent=self.adapter.split('Future<bool> thumbnailParentActive(',1)[1].split('Future<void> validateThumbnail(',1)[0]
        self.assertLess(parent.index('await _binding('),parent.index('await _descriptor('))
        self.assertIn('本机受限ref绑定错误仍fail closed，不降级为missing请求',self.prepared)
        self.assertIn('坏旅行缩略图进入缺图修复',self.prepared)

    def test_finance_validation_remains_before_travel_dispatch_and_commit(self):
        apply=self.policy.split('Future<void> apply(',2)[-1]
        self.assertLess(apply.index('validatePortableFields('),apply.index('await travel!.validateOp('))
        self.assertLess(apply.index('await _automaticSource('),apply.index('await store.merge('))
        self.assertIn("pendingProofs['$scope|$id|${op['actor']}']=op",apply)
        self.assertIn("final current=await _allowed(peer)",apply)


if __name__=='__main__': unittest.main()
