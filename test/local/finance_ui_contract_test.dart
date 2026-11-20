// Prepared regression tests only; not executed while SDK commands are blocked.
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/local/local_backend.dart';
import 'package:wo/features/plugins/retirement/finance_ui_support.dart';

const token = '12345678-1234-5678-9234-123456789abc';
class _CaptureFinance implements LocalBackend {
  final calls = <({String method, String path, Map<String, dynamic> body})>[];
  @override String get mediaBaseUrl => '';
  @override Map<String, String> get mediaHeaders => const {};
  @override
  Future<LocalResult> request(String method, String path, {Object? body,
      Map<String, dynamic>? query, List<(List<int>, String)>? files,
      Map<String, String>? fields}) async {
    calls.add((method: method, path: path, body: body is Map ? Map<String, dynamic>.from(body) : {}));
    return (data: {'id': 'row', 'family_id': 'family', 'name': '记录', 'balance': '100.00',
      'monthly_income': '0.00', 'monthly_payment': '1.00', 'amount': '1.00',
      'cycle': 'monthly', 'next_due': '2030-01-01', 'conflict_frontier': token}, meta: null);
  }
}

void main() {
  late LocalBackend? previous;
  late _CaptureFinance capture;
  late WoApi api;
  setUp(() {
    previous = ApiClient.localBackend; capture = _CaptureFinance();
    ApiClient.localBackend = capture; api = WoApi(ApiClient());
  });
  tearDown(() { ApiClient.localBackend = previous; });

  test('四类冲突与派生确认token不会被模型忽略', () {
    final account = RetireAccount.fromJson({'id': 'a', 'balance': '100.01', 'balance_conflict': true, 'settlement_conflict': true, 'conflict_frontier': token});
    expect(account.balanceConflict, true); expect(account.settlementConflict, true);
    expect(account.balanceText, '100.01'); expect(account.conflictFrontier, token);
    expect(RetireDebt.fromJson({'id': 'd', 'balance_conflict': true, 'conflict_frontier': token}).balanceConflict, true);
    expect(RetireDashboard.fromJson({'ledger_conflict': true}).ledgerConflict, true);
    expect(Subscription.fromJson({'id': 's', 'billing_conflict': true, 'conflict_frontier': token}).billingConflict, true);
  });

  test('只改账户资料时不回写打开页面时的旧余额', () async {
    await api.updateRetireAccount('family', 'a', name: '改名', kind: 'deposit', emoji: '🏦',
      balance: 100, monthlyIncome: 0, incomeDay: 1, preserveBalance: true);
    expect(capture.calls.single.body.containsKey('balance'), false);
    expect(capture.calls.single.body.containsKey('confirm_balance'), false);
  });

  test('账户确认携带GET版本和精确文本，无虚构confirm字段', () async {
    await api.updateRetireAccount('family', 'a', name: '存款', kind: 'deposit', emoji: '🏦',
      balance: 0, balanceText: '999999999999.99', monthlyIncome: 0,
      monthlyIncomeText: '0.01', incomeDay: 1, expectedConflictFrontier: token, clientId: 'confirmed');
    expect(capture.calls.single.body['balance'], '999999999999.99');
    expect(capture.calls.single.body['monthly_income'], '0.01');
    expect(capture.calls.single.body['expected_conflict_frontier'], token);
    expect(capture.calls.single.body['client_id'], 'confirmed');
  });

  test('负债确认同样带版本，普通修改可以保留余额', () async {
    await api.updateRetireDebt('family', 'd', name: '房贷', kind: 'mortgage', emoji: '🏠',
      balance: 0, balanceText: '1.23', monthlyPayment: 0, monthlyPaymentText: '0.01',
      paymentDay: 1, expectedConflictFrontier: token);
    expect(capture.calls.last.body['balance'], '1.23');
    expect(capture.calls.last.body['expected_conflict_frontier'], token);
  });

  test('订阅明确确认才发送confirm_billing并保留选定下次日期', () async {
    await api.updateSubscription('family', 's', nextDue: DateTime(2030, 2, 28),
      amount: 1, amountText: '1.01', confirmBilling: true, expectedConflictFrontier: token);
    expect(capture.calls.single.body['confirm_billing'], true);
    expect(capture.calls.single.body['expected_conflict_frontier'], token);
    expect(capture.calls.single.body['next_due'], '2030-02-28');
    expect(capture.calls.single.body['amount'], '1.01');
    await api.updateSubscription('family', 's', note: '普通备注');
    expect(capture.calls.last.body.containsKey('confirm_billing'), false);
  });

  test('金额输入不对超精度、非有限或空必填金额静默取0', () {
    expect(financeAmount('999999999999.99'), '999999999999.99');
    expect(financeAmount('0.1'), '0.10'); expect(financeAmount('', emptyZero: true), '0.00');
    for (final text in ['', 'NaN', 'Infinity', '0.001', '0.30000000000000004', '1000000000000']) {
      expect(() => financeAmount(text), throwsFormatException);
    }
    expect(() => financeAmount('0.00', subscription: true), throwsFormatException);
  });
}
