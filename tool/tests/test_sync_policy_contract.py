"""同步嵌套schema、握手限额、生命周期的静态检查；不运行Dart/SDK。"""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[2]


class SyncPolicyContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy=(ROOT/'lib/local/sync/sync_policy.dart').read_text()
        cls.stock=(ROOT/'lib/local/plugins/stock_accounting.dart').read_text()
        cls.wire=(ROOT/'lib/local/sync/sync_wire.dart').read_text()
        cls.coordinator=(ROOT/'lib/local/sync/sync_coordinator.dart').read_text()
        cls.prepared=(ROOT/'test/local/sync/portable_policy_test.dart').read_text()

    def test_public_snapshot_contract_and_palette_are_registered(self):
        self.assertIn('static const baseSchemas=',self.policy)
        self.assertIn('static const commentFields=',self.policy)
        self.assertIn("'plugins/recipe/settings':{'seeded'}",self.policy)
        self.assertIn('static void validatePortableFields(',self.policy)
        helper=self.policy.split('static void validatePortableFields(',1)[1].split('Future<Map<String,dynamic>> _validateState(',1)[0]
        self.assertNotIn("visibility']!=(scope==",helper)
        self.assertIn('String? actor,int? clock',helper)

    def test_embedded_json_is_strict_and_source_bound_on_import_and_export(self):
        self.assertIn('decodeStrictJson(value)',self.policy)
        self.assertIn('StockAccountingRoutes.decodeEvent(LocalStore.canonical(decoded),expectedId:id,actor:actor,order:clock)',self.policy)
        self.assertIn('StockAccountingRoutes.entryFields',self.policy)
        self.assertIn('StockAccountingRoutes.budgetEntryFields',self.policy)
        self.assertIn("budget['updated_by']!=actor",self.policy)
        self.assertIn('actor:store.deviceId,clock:',self.policy)
        self.assertIn('actor:peer.remoteDeviceId,clock:',self.policy)
        self.assertIn('fingerprint=_jsonObject',self.policy)
        self.assertIn('StockAccountingRoutes.requestResponseFields',self.policy)

    def test_concurrent_receipts_keep_independent_actor_clock_operations(self):
        helper=self.policy.split("if(suffix=='plugins/stock/events'){",1)[1].split("if(suffix.endsWith('/requests')",1)[0]
        self.assertNotIn("previous['event']",helper)
        self.assertIn('同event_id可有不同actor/order',helper)
        self.assertIn('final stockCreation=',self.policy)
        self.assertIn("fields['created_by']==peer.remoteDeviceId",self.policy)
        self.assertIn('&&!stockCreation',self.policy)
        self.assertIn('同receipt并发来源和时间差不拒绝',self.prepared)

    def test_business_calendar_is_independent_of_processing_timestamp(self):
        entry=self.policy.split('static void _entry(',1)[1].split('static void _request(',1)[0]
        self.assertIn('StockAccountingRoutes.decodeEntry(',entry)
        self.assertIn("!date(entry['calendar_date'])",self.stock)
        self.assertIn("DateTime.tryParse(entry['created_at'] as String)?.isUtc!=true",self.stock)
        self.assertNotIn('Duration(minutes:',entry)
        self.assertNotIn('calendarDate(calendar)',entry)
        self.assertIn("'calendar_date':'2026-01-01'",self.prepared)

    def test_request_ids_and_to_buy_response_are_checked_without_wrong_target_rule(self):
        self.assertIn("'$plugin-client:$familyId:$client'",self.policy)
        self.assertIn("if(tail.length>=3&&!toBuy&&response['id']!=tail[2])",self.policy)
        self.assertIn("if(toBuy&&response['stock_item_id']!=tail[2])",self.policy)
        self.assertIn("'creation_request'))_stockBody(_jsonObject",self.policy)
        self.assertIn('库存to-buy缓存返回新buy ID合法',self.prepared)

    def test_local_media_id_collision_cannot_authorize_private_original(self):
        self.assertIn('final localRef=await store.deviceReference(id)',self.policy)
        self.assertIn("meta['scope']!=scope||meta['memory_id']!=merged['memory_id']",self.policy)
        self.assertIn('同步媒体ID与本机受限引用冲突',self.policy)

    def test_chat_messages_require_complete_patch_and_author_only_tombstone(self):
        self.assertEqual(self.policy.count("if(suffix=='plugins/chat/messages'&&op['kind']=='patch')_fields(fields,"),2)
        self.assertIn("previous['created_by']!=actor",self.policy)
        self.assertIn("if(suffix=='plugins/chat/status')_badEmbedded()",self.policy)
        self.assertIn("fields.keys.any((k)=>fields[k]!=previous[k])",self.policy)
        self.assertIn('wo-chat-v1:$familyId:',self.policy)

    def test_preauthentication_is_bounded_before_body_and_base64_decode(self):
        self.assertIn('const _maxHandshakeBytes=2048',self.wire)
        self.assertEqual(self.wire.count('frames.read(maxBytes:_maxHandshakeBytes)'),3)
        self.assertIn('value is! String||value.length!=43',self.wire)
        self.assertIn('size>maxBytes',self.wire)
        self.assertLess(self.wire.index('size>maxBytes'),self.wire.index('final raw=await _take(size)'))
        self.assertIn('_done=true;_wake();socket.destroy()',self.wire)
        self.assertIn('if(_closed)return;_closed=true;_failed=true',self.wire)

    def test_lifecycle_ignores_stale_completions_and_awaits_sessions_before_store_close(self):
        self.assertIn('if(_disposed||epoch!=null&&!_alive(epoch))return',self.coordinator)
        self.assertIn('return _queueLife(()=>_start(epoch))',self.coordinator)
        self.assertIn('return _queueLife(_cleanup)',self.coordinator)
        self.assertIn('_readyGeneration!=epoch',self.coordinator)
        self.assertIn('identical(_busy[peer.id],token)',self.coordinator)
        self.assertIn('await Future.wait(tasks.map(',self.coordinator)
        self.assertIn('_disposed=true;unawaited(stop());super.dispose()',self.coordinator)
        self.assertIn("_check(epoch);await strategy.apply",self.coordinator)
        self.assertIn('previous?.type!=InternetAddressType.IPv4',self.coordinator)
        self.assertIn('if(next==null||!localAddress(next))return',self.coordinator)


if __name__=='__main__':
    unittest.main()
