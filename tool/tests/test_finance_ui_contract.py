"""Source contracts and independent UUID facts oracle; no SDK invocation."""
from pathlib import Path
import copy
import json
import re
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]


class FinanceUIContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.models = (ROOT / 'lib/data/models.dart').read_text()
        cls.api = (ROOT / 'lib/data/wo_api.dart').read_text()
        cls.library = (ROOT / 'lib/local/plugins/retirement_subscription.dart').read_text()
        cls.support = (ROOT / 'lib/features/plugins/retirement/finance_ui_support.dart').read_text()
        cls.account = (ROOT / 'lib/features/plugins/retirement/account_edit_page.dart').read_text()
        cls.debt = (ROOT / 'lib/features/plugins/retirement/debt_edit_page.dart').read_text()
        cls.overview = (ROOT / 'lib/features/plugins/retirement/retirement_overview_view.dart').read_text()
        cls.subscription = (ROOT / 'lib/features/plugins/subscription/subscription_page.dart').read_text()

    def test_all_financial_conflicts_reach_models_and_visible_pages(self):
        for field in ('balance_conflict', 'settlement_conflict', 'ledger_conflict', 'billing_conflict', 'conflict_frontier'):
            self.assertIn(field, self.models)
        self.assertIn('d.ledgerConflict', self.overview)
        self.assertIn('account.settlementConflict', (ROOT / 'lib/features/plugins/retirement/accounts_view.dart').read_text())
        self.assertIn('debt.balanceConflict', (ROOT / 'lib/features/plugins/retirement/debts_view.dart').read_text())
        self.assertIn('sub.billingConflict', self.subscription)

    def test_balance_correction_fetches_then_requires_explicit_confirmation(self):
        for page in (self.account, self.debt):
            self.assertLess(page.index('currentRows = (await'), page.index('showWoDialog<bool>'))
            self.assertIn('已核对，确认金额', page)
            self.assertIn('confirmed != true', page)
            self.assertIn('preserveBalance = !needsReview', page)
            self.assertIn('expectedFrontier = current.conflictFrontier', page)
            self.assertIn('expectedConflictFrontier: expectedFrontier', page)
        self.assertEqual(self.api.count("if (!isLocal || !preserveBalance) 'balance':"), 2)

    def test_billing_confirmation_has_checkbox_dialog_and_current_token(self):
        self.assertIn('CheckboxListTile', self.subscription)
        self.assertIn('if (!_reviewChecked)', self.subscription)
        self.assertIn('确认订阅账期', self.subscription)
        self.assertIn('查看已有账目', self.subscription)
        self.assertIn('expectedFrontier = latest.single.conflictFrontier', self.subscription)
        self.assertIn('confirmBilling: review, expectedConflictFrontier: expectedFrontier', self.subscription)
        self.assertIn("if (isLocal && confirmBilling) 'confirm_billing': true", self.api)

    def test_changed_frontier_invalidates_prior_human_confirmation(self):
        for page in (self.account, self.debt):
            self.assertIn('expectedFrontier != _reviewFrontier', page)
            self.assertIn('_balance.clear()', page)
            self.assertIn('_recordChanged = true', page)
            self.assertIn('当前账面金额', page)
        changed = self.subscription.split('if (_reviewRequired && expectedFrontier != null && expectedFrontier != _reviewFrontier)', 1)[1].split('if (latest.single.billingConflict', 1)[0]
        self.assertIn('_reviewChecked = false', changed)
        self.assertIn('return;', changed)
        self.assertIn('_latestBillNote', changed)

    def test_decimal_input_stays_text_on_local_wire(self):
        self.assertIn('int.parse(parts[0]) * 100', self.support)
        self.assertNotIn('double', self.support.split('String financeAmount', 1)[1].split('mixin FinanceLocalRefresh', 1)[0].replace('binary double', ''))
        self.assertIn("isLocal && balanceText != null ? balanceText : balance", self.api)
        self.assertIn("isLocal && amountText != null ? amountText : amount", self.api)
        pattern = re.search(r"RegExp\(r'([^']+)'\)", self.support).group(1)
        for text in ('0.01', '999999999999.99', '-0.01'):
            self.assertRegex(text, pattern)
        for text in ('0.001', 'NaN', '1e3', '0.30000000000000004'):
            self.assertIsNone(re.fullmatch(pattern, text))

    def test_frontier_is_compared_in_transaction_before_mutating_entry(self):
        self.assertIn('await store.batchComputed((tx)', self.library)
        account_start = self.library.index('Future<LocalResult> _retirement')
        sub_start = self.library.index('Future<LocalResult> _subscription')
        account = self.library[account_start:sub_start]
        self.assertLess(account.index("body['expected_conflict_frontier'] != frontier"), account.index("entry['balance_minor'] = minor"))
        subscription = self.library[sub_start:]
        self.assertLess(subscription.index("body['expected_conflict_frontier'] != frontier"), subscription.index("entry['acknowledged_charge_conflicts'] ="))
        self.assertNotIn("entry['conflict_frontier'] =", self.library)
        self.assertNotIn("entry['expected_conflict_frontier'] =", self.library)
        for fact in ('source_sequence', 'settlement_totals', 'account_index', 'expenses'):
            self.assertIn(fact, self.library)

    def test_frontier_oracle_changes_for_new_source_or_settlement_facts(self):
        namespace = uuid.UUID('6ba7b811-9dad-11d1-80b4-00c04fd430c8')
        facts = {'schema': 1, 'family_id': 'family', 'plugin': 'retirement', 'resource': 'accounts',
                 'record_id': 'account', 'entry': {'balance_minor': 100}, 'events': [],
                 'settlement_totals': {}, 'account_index': [], 'expenses': []}
        def token(value):
            return uuid.uuid5(namespace, 'wo-finance-frontier-v1:' + json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')))
        before = token(facts)
        self.assertEqual(before.version, 5)
        self.assertEqual(before, token(copy.deepcopy(facts)))
        changed = copy.deepcopy(facts)
        changed['events'].append({'event_id': 'income', 'actor': 'peer', 'order': 1, 'source_sequence': 1, 'amount_minor': 5})
        self.assertNotEqual(before, token(changed))
        changed = copy.deepcopy(facts)
        changed['settlement_totals']['2026-10'] = 1500
        self.assertNotEqual(before, token(changed))
        changed = copy.deepcopy(facts)
        changed['entry']['balance_minor'] = 101
        self.assertNotEqual(before, token(changed))

    def test_local_refresh_retains_cache_and_unsubscribes(self):
        self.assertIn('changes.addListener(_changed)', self.support)
        self.assertIn('changes.removeListener(_changed)', self.support)
        for file in ('accounts_view.dart', 'debts_view.dart', 'retirement_overview_view.dart'):
            source = (ROOT / 'lib/features/plugins/retirement' / file).read_text()
            self.assertIn('bindFinanceChanges', source)
            self.assertIn('ticket == _ticket && family == _familyId', source)
        self.assertIn('bindFinanceChanges', self.subscription)

    def test_honest_foreground_state_and_real_avatars(self):
        self.assertIn('后台执行与历史补算尚未完成', self.support)
        self.assertIn('不代表已送达', self.support)
        for file in ('accounts_view.dart', 'debts_view.dart'):
            self.assertIn('MemberAvatar', (ROOT / 'lib/features/plugins/retirement' / file).read_text())
        self.assertIn('MemberAvatar(url: sub.creatorAvatarUrl', self.subscription)
        self.assertIn('!debt.active && !debt.balanceConflict', (ROOT / 'lib/features/plugins/retirement/debts_view.dart').read_text())


if __name__ == '__main__':
    unittest.main()
