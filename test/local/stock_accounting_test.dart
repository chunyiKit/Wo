// Prepared SQLite/Dart tests; intentionally not run while native SDK execution is blocked.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/local/local_backend.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/stock_accounting.dart';

void main() {
  sqfliteFfiInit();
  const fid = 'stock-family';
  late Directory directory;
  late LocalStore store;
  late StockAccountingRoutes routes;
  late DateTime clock;
  Future<void> member(LocalStore value) async {
    await value.patch(fid, '/families/$fid/members', value.deviceId, {
      'family_id': fid, 'user_id': value.deviceId, 'status': 'active',
      'display_name': '真实成员', 'avatar_emoji': '🐱',
      'avatar_url': '/local/member/avatar?v=3',
    });
  }
  Future<LocalResult> call(String verb, List<String> tail, {Json body = const {}, Json query = const {}}) async =>
      (await routes.request(verb, fid, tail, body: body, query: query))!;
  Future<Json> row(String verb, List<String> tail, {Json body = const {}}) async =>
      Json.from((await call(verb, tail, body: body)).data as Map);
  Matcher apiError(int status) => throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', status));
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wo-stock-accounting-');
    store = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/local.sqlite');
    clock = DateTime(2026, 11, 30, 23, 59);
    routes = StockAccountingRoutes(store, now: () => clock);
    await member(store);
  });
  tearDown(() async { await store.close(); await directory.delete(recursive: true); });

  test('库存原契约、告急、真实作者头像和本机重启', () async {
    final created = await row('POST', ['stock', 'items'], body: {'name': ' 米 ', 'qty': 3, 'unit': '袋', 'low_at': 3});
    expect(created['qty'], 3); expect(created['is_low'], true);
    expect(created['creator_avatar_url'], '/local/member/avatar?v=3');
    final changed = await row('PUT', ['stock', 'items', created['id'] as String], body: {'qty': 7, 'note': null});
    expect(changed['qty'], 7); expect(changed['is_low'], false);
    expect((await call('GET', ['stock', 'items'], query: {'low': true})).data, isEmpty);
    await store.close();
    store = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/local.sqlite');
    routes = StockAccountingRoutes(store);
    expect((await row('GET', ['stock', 'items', created['id'] as String]))['qty'], 7);
  });

  test('调整和创建 client_id 可重试，冲突 payload 不复用', () async {
    final body = {'name': '米', 'qty': 3, 'client_id': 'create-rice'};
    final created = await row('POST', ['stock', 'items'], body: body);
    expect((await row('POST', ['stock', 'items'], body: body))['id'], created['id']);
    final path = ['stock', 'items', created['id'] as String, 'adjust'];
    final adjusted = await row('POST', path, body: {'delta_qty': 2, 'client_id': 'add-two'});
    expect(adjusted['qty'], 5);
    expect((await row('POST', path, body: {'delta_qty': 2, 'client_id': 'add-two'}))['qty'], 5);
    await expectLater(call('POST', path, body: {'delta_qty': 3, 'client_id': 'add-two'}), apiError(409));
    await expectLater(call('POST', path, body: {'delta_qty': -6}), apiError(409));
    expect((await row('GET', path.take(3).toList()))['qty'], 5);
  });

  test('采买关联、收货无 client_id 重试幂等，重开不撤销入库', () async {
    final item = await row('POST', ['stock', 'items'], body: {'name': '米', 'qty': 1});
    final linked = ['stock', 'items', item['id'] as String, 'to-buy'];
    final buy = await row('POST', linked);
    expect((await row('POST', linked))['id'], buy['id']);
    final receipt = ['stock', 'buys', buy['id'] as String, 'bought'];
    final received = await row('POST', receipt, body: {'into_stock_qty': 4, 'client_id': 'receipt-once'});
    expect(received['bought'], true);
    await row('POST', receipt, body: {'into_stock_qty': 4});
    expect((await row('GET', ['stock', 'items', item['id'] as String]))['qty'], 5);
    final reopened = await row('POST', ['stock', 'buys', buy['id'] as String, 'reopen']);
    expect(reopened['bought'], false);
    await row('POST', receipt, body: {'into_stock_qty': 4, 'client_id': 'receipt-once'});
    expect((await row('GET', ['stock', 'items', item['id'] as String]))['qty'], 5);
    await row('POST', receipt, body: {'into_stock_qty': 2, 'client_id': 'next-receipt'});
    expect((await row('GET', ['stock', 'items', item['id'] as String]))['qty'], 7);
  });

  test('未关联采买创建新库存，删除采买保留已收货数量', () async {
    final buy = await row('POST', ['stock', 'buys'], body: {'name': '牛奶', 'want_qty': '两箱'});
    final received = await row('POST', ['stock', 'buys', buy['id'] as String, 'bought'], body: {'into_stock_qty': 2});
    expect(received['stock_item_id'], isNotNull);
    final id = received['stock_item_id'] as String;
    await call('DELETE', ['stock', 'buys', buy['id'] as String]);
    expect((await row('GET', ['stock', 'items', id]))['qty'], 2);
  });

  test('删除库存不被旧收货复活，采买链接显示断开', () async {
    final item = await row('POST', ['stock', 'items'], body: {'name': '米', 'qty': 1});
    final buy = await row('POST', ['stock', 'items', item['id'] as String, 'to-buy']);
    await call('DELETE', ['stock', 'items', item['id'] as String]);
    await expectLater(call('POST', ['stock', 'buys', buy['id'] as String, 'bought'], body: {'into_stock_qty': 2}), apiError(409));
    expect((await row('GET', ['stock', 'buys', buy['id'] as String]))['stock_item_id'], isNull);
    expect((await call('GET', ['stock', 'items'])).data, isEmpty);
  });

  test('两端离线增量全部保留，合并负库存明确标记后盘点恢复', () async {
    final other = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/other.sqlite');
    try {
      await member(other);
      await store.merge(fid, await other.exportSince(fid, await store.vector(fid)));
      final item = await row('POST', ['stock', 'items'], body: {'name': '米', 'qty': 3});
      await other.merge(fid, await store.exportSince(fid, await other.vector(fid)));
      final otherRoutes = StockAccountingRoutes(other);
      final path = ['stock', 'items', item['id'] as String, 'adjust'];
      await call('POST', path, body: {'delta_qty': -2, 'client_id': 'left-use'});
      await otherRoutes.request('POST', fid, path, body: {'delta_qty': -2, 'client_id': 'right-use'});
      await store.merge(fid, await other.exportSince(fid, await store.vector(fid)));
      await other.merge(fid, await store.exportSince(fid, await other.vector(fid)));
      final conflict = await row('GET', path.take(3).toList());
      expect(conflict['qty'], -1); expect(conflict['raw_qty'], -1); expect(conflict['quantity_conflict'], true);
      await expectLater(call('POST', path, body: {'delta_qty': 1}), apiError(409));
      final counted = await row('PUT', path.take(3).toList(), body: {'qty': 5, 'confirm_stocktake': true});
      expect(counted['qty'], 5); expect(counted['quantity_conflict'], false);
      await other.merge(fid, await store.exportSince(fid, await other.vector(fid)));
      final read = await otherRoutes.request('GET', fid, path.take(3).toList());
      expect((read!.data as Map)['qty'], 5);
    } finally { await other.close(); }
  });

  test('同机并发收货只入库一次，错误不能留下半个库存', () async {
    final buy = await row('POST', ['stock', 'buys'], body: {'name': '米'});
    final path = ['stock', 'buys', buy['id'] as String, 'bought'];
    await Future.wait([for (var i = 0; i < 8; i++) call('POST', path, body: {'into_stock_qty': 3})]);
    final items = (await call('GET', ['stock', 'items'])).data as List;
    expect(items, hasLength(1)); expect((items.single as Map)['qty'], 3);
    await expectLater(call('POST', path, body: {'into_stock_qty': -1}), apiError(400));
    expect(((await call('GET', ['stock', 'items'])).data as List), hasLength(1));
  });

  test('未知路由不接管，跨家庭和伪造作者/浮点数量失败', () async {
    expect(await routes.request('GET', fid, ['other', 'items']), isNull);
    await expectLater(routes.request('GET', 'foreign', ['stock', 'items']), apiError(403));
    await expectLater(call('POST', ['stock', 'items'], body: {'name': '米', 'qty': 1.5}), apiError(400));
    await expectLater(call('POST', ['stock', 'items'], body: {'name': '米', 'qty': 1, 'created_by': 'forged'}), apiError(400));
  });

  test('账目整分存储、预算内外统计及真实作者头像', () async {
    final one = await row('POST', ['accounting', 'transactions'], body: {'amount': 0.1, 'category': 'dining', 'client_id': 'expense-one'});
    expect(one['amount'], '0.10'); expect(one['amount_minor'], 10);
    expect(one['creator_avatar_url'], '/local/member/avatar?v=3');
    await row('POST', ['accounting', 'transactions'], body: {'amount': '0.20', 'category': 'snack'});
    await row('POST', ['accounting', 'transactions'], body: {'amount': '1.00', 'category': 'shopping', 'exclude_from_budget': true});
    await row('PUT', ['accounting', 'budget'], body: {'monthly_amount': '1.00'});
    final summary = await row('GET', ['accounting', 'summary']);
    expect(summary['month_total'], '1.30'); expect(summary['budgeted_total'], '0.30');
    expect(summary['excluded_total'], '1.00'); expect(summary['remaining'], '0.70');
    final docs = await store.list(fid, '/families/$fid/plugins/accounting/transactions');
    expect(docs.every((doc) => doc['entry'] is String && !doc.containsKey('amount')), true);
    final repeated = await row('POST', ['accounting', 'transactions'], body: {'amount': 0.1, 'category': 'dining', 'client_id': 'expense-one'});
    expect(repeated['id'], one['id']);
    expect((await call('GET', ['accounting', 'transactions'])).data as List, hasLength(3));
  });

  test('月份按记录时本机日历日，闰日与跨年不采用30天窗口', () async {
    clock = DateTime(2024, 2, 29, 23, 59);
    await row('POST', ['accounting', 'transactions'], body: {'amount': '2.29', 'category': 'dining'});
    clock = DateTime(2024, 3, 1);
    await row('POST', ['accounting', 'transactions'], body: {'amount': '3.01', 'category': 'dining'});
    final feb = await call('GET', ['accounting', 'summary'], query: {'year': '2024', 'month': '2'});
    expect((feb.data as Map)['month_total'], '2.29');
    clock = DateTime(2025, 12, 31, 23, 59);
    await row('POST', ['accounting', 'transactions'], body: {'amount': '12.31', 'category': 'dining'});
    clock = DateTime(2026, 1, 1);
    await row('POST', ['accounting', 'transactions'], body: {'amount': '1.01', 'category': 'dining'});
    final dec = await call('GET', ['accounting', 'transactions'], query: {'year': 2025, 'month': 12});
    expect(dec.data as List, hasLength(1));
    final jan = await call('GET', ['accounting', 'summary'], query: {'year': 2026, 'month': 1});
    expect((jan.data as Map)['month_total'], '1.01');
    await expectLater(call('GET', ['accounting', 'summary'], query: {'year': 2026, 'month': 13}), apiError(400));
    await expectLater(call('GET', ['accounting', 'transactions'], query: {'year': 2026}), apiError(400));
  });

  test('自定义分类稳定代码与去重，修改删除账目和退款', () async {
    final category = await row('POST', ['accounting', 'categories'], body: {'label': ' 医疗 ', 'emoji': '🏥', 'client_id': 'category-medical'});
    expect(category['label'], '医疗'); expect((category['code'] as String).length, 16);
    await expectLater(call('POST', ['accounting', 'categories'], body: {'label': '医疗'}), apiError(422));
    await expectLater(call('POST', ['accounting', 'categories'], body: {'label': '餐饮'}), apiError(422));
    final expense = await row('POST', ['accounting', 'transactions'], body: {'amount': '12.34', 'category': category['code']});
    final id = expense['id'] as String;
    final edited = await row('PUT', ['accounting', 'transactions', id], body: {'amount': '-1.23', 'note': null, 'exclude_from_budget': true});
    expect(edited['amount_minor'], -123); expect(edited['category'], category['code']);
    await call('DELETE', ['accounting', 'transactions', id]);
    expect((await call('GET', ['accounting', 'transactions'])).data, isEmpty);
  });

  test('超精度/非有限金额与不存在分类失败，不写半条账目', () async {
    for (final amount in ['0.001', 'NaN', double.nan, double.infinity, '10000000000.00', '0.30000000000000004']) {
      await expectLater(call('POST', ['accounting', 'transactions'], body: {'amount': amount, 'category': 'dining'}), apiError(400));
    }
    await expectLater(call('POST', ['accounting', 'transactions'], body: {'amount': '1.00', 'category': 'foreign-category'}), apiError(422));
    await expectLater(call('PUT', ['accounting', 'budget'], body: {'monthly_amount': '-1'}), apiError(400));
    expect((await call('GET', ['accounting', 'transactions'])).data, isEmpty);
    await expectLater(call('POST', ['accounting', 'receipt-scan']), apiError(501));
  });

  test('两端独立账目合并不丢失，整个编辑entry不拼接字段', () async {
    final other = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/accounting-other.sqlite');
    try {
      await member(other);
      await store.merge(fid, await other.exportSince(fid, await store.vector(fid)));
      await other.merge(fid, await store.exportSince(fid, await other.vector(fid)));
      final otherRoutes = StockAccountingRoutes(other, now: () => clock);
      final left = await row('POST', ['accounting', 'transactions'], body: {'amount': '0.10', 'category': 'dining'});
      await otherRoutes.request('POST', fid, ['accounting', 'transactions'], body: {'amount': '0.20', 'category': 'snack'});
      await store.merge(fid, await other.exportSince(fid, await store.vector(fid)));
      await other.merge(fid, await store.exportSince(fid, await other.vector(fid)));
      expect((await row('GET', ['accounting', 'summary']))['month_total'], '0.30');
      final path = ['accounting', 'transactions', left['id'] as String];
      await call('PUT', path, body: {'amount': '2.00', 'category': 'shopping', 'exclude_from_budget': true});
      await otherRoutes.request('PUT', fid, path, body: {'amount': '3.00', 'category': 'pet', 'exclude_from_budget': false});
      await store.merge(fid, await other.exportSince(fid, await store.vector(fid)));
      await other.merge(fid, await store.exportSince(fid, await other.vector(fid)));
      final read = await row('GET', path);
      final combined = [read['amount'], read['category'], read['exclude_from_budget']];
      expect(combined, anyOf(equals(['2.00', 'shopping', true]), equals(['3.00', 'pet', false])));
    } finally { await other.close(); }
  });


  test('同步库存事件语义不含来源字段且拒绝未知嵌套字段', () {
    final event = {'event_id': 'receipt-one', 'type': 'receipt', 'buy_id': 'buy-one',
      'cycle': 'initial', 'item_id': 'rice', 'delta': 3, 'order': 1,
      'actor': 'device-one', 'created_at': '2026-11-20T00:00:00Z'};
    final other = {...event, 'order': 2, 'actor': 'device-two', 'created_at': '2026-11-21T00:00:00Z'};
    expect(StockAccountingRoutes.eventSemantic(event), StockAccountingRoutes.eventSemantic(other));
    expect(StockAccountingRoutes.eventSemantic(event), isNot(StockAccountingRoutes.eventSemantic({...event, 'delta': 4})));
    expect(StockAccountingRoutes.syncFields['plugins/stock/items'], isNot(contains('qty')));
    expect(StockAccountingRoutes.immutableCollections, contains('plugins/stock/events'));
    expect(() => StockAccountingRoutes.decodeEvent(LocalStore.canonical({...event, 'bookmark': 'forbidden'})), throwsFormatException);
    expect(StockAccountingRoutes.decodeEvent(LocalStore.canonical(event), actor: 'device-one', order: 1)['delta'], 3);
    expect(() => StockAccountingRoutes.decodeEvent(LocalStore.canonical(event), actor: 'device-other'), throwsFormatException);
  });

}
