"""财务同步来源的静态契约；不运行Dart、SQLite用例或任何手机SDK。"""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[2]


class FinanceSyncContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy=(ROOT/'lib/local/sync/sync_policy.dart').read_text()
        cls.stock=(ROOT/'lib/local/plugins/stock_accounting.dart').read_text()
        cls.finance=(ROOT/'lib/local/plugins/retirement_subscription.dart').read_text()
        cls.tests=(ROOT/'test/local/sync/finance_source_test.dart').read_text()

    def test_manual_nine_and_optional_whole_source_group(self):
        self.assertIn('static const entryBaseFields =',self.stock)
        self.assertIn("static const entrySourceFields = <String>{'source_plugin', 'source_id', 'source_occurrence', 'source_event_id'}",self.stock)
        self.assertIn('entrySourceFields.any(entry.containsKey)',self.stock)
        self.assertIn('!entrySourceFields.every(entry.containsKey)',self.stock)
        self.assertIn('decodeBackupJson(encoded)',self.stock)
        self.assertIn("subscription-charge:$familyId:",self.stock)
        self.assertIn("subscription-expense:$familyId:",self.stock)
        self.assertIn("entry['calendar_date']!=entry['source_occurrence']",self.stock)

    def test_manual_api_does_not_accept_or_overwrite_source_body_fields(self):
        accounting=self.stock.split('Future<LocalResult> _accounting(',1)[1].split('/// Merge-order',1)[0]
        self.assertIn("only(body, {'amount', 'category', 'note', 'exclude_from_budget', 'client_id'})",accounting)
        self.assertIn("_entry(await _required(tx, fid, collection, id))..remove('id')..remove('amount')",accounting)
        self.assertNotIn("body['source_plugin']",accounting)
        self.assertNotIn("body['source_id']",accounting)

    def test_financial_json_and_immutable_event_source_use_strict_shared_decoder(self):
        self.assertIn('RetirementSubscriptionRoutes.decodeEvent(LocalStore.canonical(decoded),expectedId:id,actor:actor,order:clock',self.policy)
        self.assertIn('RetirementSubscriptionRoutes.immutableCollections.contains(suffix)',self.policy)
        self.assertIn("if(deletion)_badEmbedded();_fields(fields,{'event'},{});_financeEvent",self.policy)
        for schema in ('accountEntryFields','debtEntryFields','planEntryFields','subscriptionEntryFields','requestResponseFields'):
            self.assertIn('RetirementSubscriptionRoutes.'+schema,self.policy)
        self.assertIn('final fp=_jsonObject(fields[\'fingerprint\'])',self.policy)
        self.assertIn('retirement:$familyId:',self.policy)

    def test_charge_proof_must_come_from_same_batch_or_authenticated_actor_log(self):
        proof=self.policy.split('Future<({bool initial,bool priorOrigin})> _automaticSource(',1)[1].split('static void _financeNotification(',1)[0]
        self.assertIn('Json? proof=pendingProofs[key]',proof)
        self.assertIn("where:'space=? AND actor=? AND instr(payload,?)>0'",proof)
        self.assertIn("op['collection']==collection&&op['id']==sourceId&&op['actor']==creator&&op['kind']=='patch'",proof)
        self.assertIn("actor:creator,clock:proof['clock'] as int",proof)
        self.assertIn("charge['auto_recorded']!=true",proof)
        self.assertIn("charge['subscription_id']!=entry['source_id']",proof)
        self.assertIn("charge['due']!=entry['source_occurrence']",proof)
        for field in ('amount_minor','accounting_category','exclude_from_budget'):
            self.assertIn("charge['"+field+"']",proof)
        self.assertIn('if(previous==null&&!initial)_badEmbedded()',proof)

    def test_prior_origin_is_a_real_earlier_operation_not_a_validation_bypass(self):
        self.assertNotIn('historicalExport',self.policy)
        self.assertIn("op['actor']!=creator",self.policy)
        self.assertIn("(op['clock'] as int)<=charge['order']",self.policy)
        self.assertIn("(op['clock'] as int)>=clock",self.policy)
        self.assertIn("value['created_at']==entry['created_at']",self.policy)
        self.assertIn('StockAccountingRoutes.entrySourceFields.every((k)=>value[k]==entry[k])',self.policy)
        self.assertIn('if(originChanged&&!initial&&!priorOrigin)_badEmbedded()',self.policy)
        self.assertIn('verifiedAutomaticSource:verified.initial,verifiedPriorOrigin:verified.priorOrigin',self.policy)
        self.assertIn('StockAccountingRoutes.decodeEntry(LocalStore.canonical(value)',self.policy)

    def test_same_source_differences_do_not_turn_into_double_addition(self):
        self.assertIn('同due两机processor/createdAt/offset真实差异合并成一笔',self.tests)
        self.assertIn('金额语义冲突保留两份源charge',self.tests)
        self.assertIn('已认证初始op证明保留A原来源',self.tests)
        self.assertIn("'created_by': store.deviceId",self.finance)
        self.assertIn("'calendar_date': due",self.finance)
        self.assertIn("'source_plugin': 'subscription'",self.finance)
        self.assertIn("'accounting_category', 'exclude_from_budget'",self.finance)

    def test_finance_notifications_are_requests_not_foreign_delivery_receipts(self):
        self.assertIn("fields['status']!='pending_local_delivery'",self.policy)
        self.assertIn("(fields['read_by'] as List).isNotEmpty",self.policy)
        self.assertIn('final financeNotice=',self.policy)
        self.assertIn("'source_plugin','source_id','type'",self.policy)
        self.assertNotIn("fields['status']=='delivered'",self.policy)


if __name__=='__main__':
    unittest.main()
