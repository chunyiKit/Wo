// Prepared only. No Flutter/Dart/SDK execution was performed for this module.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/local/local_backend.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/retirement_subscription.dart';
import 'package:wo/local/plugins/stock_accounting.dart';

void main() {
  sqfliteFfiInit();
  const fid = 'retire-family';
  late Directory directory;
  late LocalStore store;
  late RetirementSubscriptionRoutes routes;
  late DateTime clock;
  Future<void> member(LocalStore value) async {
    await value.patch(fid, '/families/$fid/members', value.deviceId,
      {'family_id': fid, 'user_id': value.deviceId, 'status': 'active', 'display_name': '本机作者', 'avatar_emoji': '🐱', 'avatar_url': '/local/member/avatar?v=2'});
  }
  Future<void> install(String plugin) async { await store.patch(fid, '/families/$fid/installed', plugin, {'plugin_id': plugin, 'enabled': true}); }
  Future<LocalResult> call(String method, List<String> tail, {Json body = const {}, Json query = const {}}) async =>
    (await routes.request(method, fid, tail, body: body, query: query))!;
  Future<Json> row(String method, List<String> tail, {Json body = const {}}) async => Json.from((await call(method, tail, body: body)).data as Map);
  Matcher error(int status) => throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', status));
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wo-retire-sub-');
    store = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/local.sqlite');
    clock = DateTime(2026, 11, 1, 12); routes = RetirementSubscriptionRoutes(store, now: () => clock);
    await member(store); await install('retirement');
  });
  tearDown(() async { await store.close(); await directory.delete(recursive: true); });

  test('账户负债原字段、真实头像和精确金额持久化', () async {
    final account = await row('POST', ['retirement', 'accounts'], body: {'name': '存款', 'balance': '999999999999.99', 'monthly_income': '0.01'});
    expect(account['balance'], '999999999999.99'); expect(account['creator_avatar_url'], '/local/member/avatar?v=2');
    final debt = await row('POST', ['retirement', 'debts'], body: {'name': '月供', 'balance': '10.00', 'monthly_payment': '3.00', 'from_account_id': account['id']});
    expect(debt['from_account_id'], account['id']); expect(debt['monthly_payment'], '3.00');
    await expectLater(call('POST', ['retirement', 'accounts'], body: {'name': '错', 'balance': '0.001'}), error(400));
    await expectLater(call('POST', ['retirement', 'debts'], body: {'name': '错', 'balance': '1.00', 'monthly_payment': 1, 'from_account_id': 'foreign'}), error(404));
    await store.close(); store = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/local.sqlite');
    routes = RetirementSubscriptionRoutes(store, now: () => clock);
    expect((await row('GET', ['retirement', 'accounts', account['id'] as String]))['balance'], '999999999999.99');
  });

  test('创建月发薪日已过不补发、按月唯一收入与债务本金封顶', () async {
    clock = DateTime(2026, 11, 20);
    final account = await row('POST', ['retirement', 'accounts'], body: {'name': '存款', 'balance': '100.00', 'monthly_income': '5.00', 'income_day': 1});
    final debt = await row('POST', ['retirement', 'debts'], body: {'name': '月供', 'balance': '3.00', 'monthly_payment': '5.00', 'payment_day': 1, 'from_account_id': account['id']});
    await routes.processDue(fid);
    expect((await row('GET', ['retirement', 'accounts', account['id'] as String]))['balance'], '97.00');
    expect((await row('GET', ['retirement', 'debts', debt['id'] as String]))['active'], false);
    expect(await routes.processDue(fid), 0);
    clock = DateTime(2026, 12, 1); await routes.processDue(fid);
    expect((await row('GET', ['retirement', 'accounts', account['id'] as String]))['balance'], '102.00');
    final notices = await store.list(fid, '/families/$fid/notifications');
    expect(notices, isNotEmpty); expect(notices.every((n) => n['status'] == 'pending_local_delivery' && !n.containsKey('delivered_at')), true);
  });

  test('上月日历支出结算和本月新建账户不被追扣', () async {
    clock = DateTime(2026, 10, 15);
    final account = await row('POST', ['retirement', 'accounts'], body: {'name': '存款', 'balance': '100.00'});
    final accounting = StockAccountingRoutes(store, now: () => clock);
    await accounting.request('POST', fid, ['accounting', 'transactions'], body: {'amount': '12.34', 'category': 'dining'});
    clock = DateTime(2026, 11, 1); await routes.processDue(fid);
    expect((await row('GET', ['retirement', 'accounts', account['id'] as String]))['balance'], '87.66');
    final ledger = (await call('GET', ['retirement', 'ledger'])).data as List;
    expect((ledger.single as Map)['period'], '2026-11'); expect((ledger.single as Map)['note'], contains('2026-10'));
    expect(await routes.processDue(fid), 0);
  });

  test('退休年月差、目标ceil与整分half-even和口径切换', () async {
    clock = DateTime(2026, 12, 31);
    await row('POST', ['retirement', 'accounts'], body: {'name': '存款', 'balance': '10.00', 'monthly_income': '0.03'});
    await row('PUT', ['retirement', 'plan'], body: {'retire_date': '2027-02-01', 'savings_goal': '10.05', 'goal_basis': 'deposit_only', 'surplus_basis': 'income_only'});
    final dash = await row('GET', ['retirement', 'dashboard']);
    expect(dash['months_to_retire'], 2); expect(dash['days_to_retire'], 32);
    expect(dash['months_to_goal'], 2); expect(dash['required_monthly'], '0.02'); expect(dash['monthly_gap'], '0.01');
    await row('PUT', ['retirement', 'plan'], body: {'retire_date': null, 'savings_goal': null});
    final empty = await row('GET', ['retirement', 'dashboard']); expect(empty['required_monthly'], isNull); expect(empty['goal_reached'], false);
  });

  test('订阅月末夹日、年费闰日、逾期一轮推进与按到期日自动记账', () async {
    await install('accounting'); clock = DateTime(2023, 1, 31);
    final sub = await row('POST', ['subscription', 'subscriptions'], body: {'name': '服务', 'amount': '9.99', 'next_due': '2023-01-31', 'cycle': 'monthly'});
    clock = DateTime(2023, 3, 5);
    await routes.processDue(fid);
    expect((await row('GET', ['subscription', 'subscriptions', sub['id'] as String]))['next_due'], '2023-02-28');
    await routes.processDue(fid);
    expect((await row('GET', ['subscription', 'subscriptions', sub['id'] as String]))['next_due'], '2023-03-28');
    final expenses = await store.list(fid, '/families/$fid/plugins/accounting/transactions'); expect(expenses, hasLength(2));
    final accounting = StockAccountingRoutes(store, now: () => clock);
    final summary = await accounting.request('GET', fid, ['accounting', 'summary'], query: {'year': 2023, 'month': 2});
    expect((summary!.data as Map)['month_total'], '9.99');
    expect(RetirementSubscriptionRoutes.advanceDue('2024-02-29', 'yearly'), '2025-02-28');
  });

  test('订阅预提醒仅排队、暂停不处理、client_id重试不重复', () async {
    clock = DateTime(2026, 11, 1);
    final body = {'name': '服务', 'amount': '1.00', 'next_due': '2026-11-03', 'client_id': 'one-sub'};
    final sub = await row('POST', ['subscription', 'subscriptions'], body: body);
    expect((await row('POST', ['subscription', 'subscriptions'], body: body))['id'], sub['id']);
    expect(await routes.processDue(fid), 1); expect(await routes.processDue(fid), 0);
    final notifications = await store.list(fid, '/families/$fid/notifications'); expect(notifications, hasLength(1));
    expect(notifications.single['status'], 'pending_local_delivery');
    await row('PUT', ['subscription', 'subscriptions', sub['id'] as String], body: {'active': false});
    clock = DateTime(2026, 11, 5); expect(await routes.processDue(fid), 0);
    expect((await row('GET', ['subscription', 'subscriptions', sub['id'] as String]))['next_due'], '2026-11-03');
  });

  test('两端同账期收入合并只记一次，来源字段差异不是财务冲突', () async {
    final other = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/other.sqlite');
    try {
      await member(other); await store.merge(fid, await other.exportSince(fid, await store.vector(fid)));
      final account = await row('POST', ['retirement', 'accounts'], body: {'name': '存款', 'balance': '0', 'monthly_income': '5.00'});
      await other.merge(fid, await store.exportSince(fid, await other.vector(fid)));
      final right = RetirementSubscriptionRoutes(other, now: () => clock);
      await routes.processDue(fid); await right.processDue(fid);
      await store.merge(fid, await other.exportSince(fid, await store.vector(fid)));
      await other.merge(fid, await store.exportSince(fid, await other.vector(fid)));
      final read = await row('GET', ['retirement', 'accounts', account['id'] as String]);
      expect(read['balance'], '5.00'); expect(read['balance_conflict'], false);
      expect((await call('GET', ['retirement', 'ledger'])).data as List, hasLength(1));
    } finally { await other.close(); }
  });

  test('外来家庭、伪造作者、非法日期/日号和未知路由', () async {
    expect(await routes.request('GET', fid, ['other', 'accounts']), isNull);
    await expectLater(routes.request('GET', 'foreign', ['retirement', 'accounts']), error(403));
    await expectLater(call('POST', ['retirement', 'accounts'], body: {'name': '存款', 'balance': 1, 'income_day': 31}), error(400));
    await expectLater(call('POST', ['subscription', 'subscriptions'], body: {'name': '服务', 'amount': 1, 'next_due': '2023-02-29'}), error(400));
    await expectLater(call('POST', ['retirement', 'accounts'], body: {'name': '存款', 'balance': 1, 'created_by': 'forged'}), error(400));
  });

  test('上期离线账目迟到或修改标明结算冲突，余额核对不二次扣款', () async {
    clock = DateTime(2026, 10, 1);
    final account = await row('POST', ['retirement', 'accounts'], body: {'name': '存款', 'balance': '100.00'});
    final accounting = StockAccountingRoutes(store, now: () => clock);
    final expense = await accounting.request('POST', fid, ['accounting', 'transactions'], body: {'amount': '10.00', 'category': 'dining'});
    clock = DateTime(2026, 11, 1); await routes.processDue(fid);
    await accounting.request('PUT', fid, ['accounting', 'transactions', (expense!.data as Map)['id'] as String], body: {'amount': '15.00'});
    final pending = await row('GET', ['retirement', 'accounts', account['id'] as String]);
    expect(pending['balance'], '90.00'); expect(pending['settlement_conflict'], true);
    expect(await routes.processDue(fid), 0);
    final counted = await row('PUT', ['retirement', 'accounts', account['id'] as String], body: {'balance': '85.00'});
    expect(counted['balance'], '85.00'); expect(counted['settlement_conflict'], false);
  });

}
