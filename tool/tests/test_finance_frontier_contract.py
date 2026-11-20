"""frontier同步schema静态检查，不证明Dart/SQLite事务已执行。"""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]

class FinanceFrontierContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy=(ROOT/'lib/local/sync/sync_policy.dart').read_text()
        cls.stock=(ROOT/'lib/local/plugins/stock_accounting.dart').read_text()
    def test_frontier_is_canonical_uuid_v5(self):
        self.assertIn('value.length==36',self.policy)
        self.assertIn('[a-f0-9]{4}-5[a-f0-9]{3}-[89ab]',self.policy)
    def test_existing_balance_and_billing_confirmation_require_expected_frontier(self):
        self.assertIn("tail.length==3&&method=='PUT'",self.policy)
        self.assertIn("subscription?body['confirm_billing']==true:!plan&&body.containsKey('balance')",self.policy)
        self.assertIn("!_frontier(body['expected_conflict_frontier'])",self.policy)
        self.assertIn("body.containsKey('expected_conflict_frontier')",self.policy)
    def test_account_debt_subscription_response_requires_frontier_but_plan_does_not(self):
        self.assertIn("'billing_conflict','conflict_frontier'",self.policy)
        self.assertIn("'monthly_payment','conflict_frontier'",self.policy)
        self.assertIn("'settlement_conflict','conflict_frontier'",self.policy)
        self.assertIn("_frontier(response['conflict_frontier'])",self.policy)
        self.assertIn("_fields(response,{'retire_date','savings_goal','goal_basis','surplus_basis'},{})",self.policy)
    def test_frontier_is_not_a_business_entry_or_native_secret(self):
        source=self.stock.split('static const entryBaseFields',1)[1].split('static const budgetEntryFields',1)[0]
        self.assertNotIn('conflict_frontier',source)
        self.assertNotIn('putSecret',self.policy)
    def test_signed_amount_bounds_do_not_depend_on_abs_endpoint_behavior(self):
        self.assertIn("(entry['amount_minor'] as int)<-maxMinor",self.stock)
        self.assertIn("_integer(event['amount_minor'],-RetirementSubscriptionRoutes.safeInteger",self.policy)
        self.assertIn("_integer(decoded['delta'],-StockAccountingRoutes.safeMinor",self.policy)

if __name__=='__main__':unittest.main()
