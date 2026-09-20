import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/features/plugins/accounting/expense_categories.dart';
import 'package:wo/features/plugins/subscription/subscription_page.dart';
import 'package:wo/theme/wo_theme.dart';
import 'package:wo/theme/wo_tokens.dart';

import 'support/cinema_fixtures.dart';

Map<String, dynamic> _subscription({bool autoRecord = true}) => {
      'id': 's1',
      'family_id': 'cinema-family',
      'name': '房租',
      'emoji': '🏠',
      'amount': '100',
      'cycle': 'monthly',
      'next_due': '2026-10-01',
      'auto_record': autoRecord,
      'accounting_category': 'c_rent',
      'exclude_from_budget': true,
    };

Future<WoSession> _session(
  List<Map<String, dynamic>> saved, {
  bool failCategoriesOnce = false,
}) async {
  var attempts = 0;
  final categories = [
    for (final c in expenseCategories)
      {'code': c.code, 'label': c.label, 'emoji': c.emoji},
    {'code': 'c_rent', 'label': '房租', 'emoji': '🏠'},
  ];
  final client = MockClient((request) async {
    Object? data;
    if (request.url.path.endsWith('/accounting/categories')) {
      if (request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        categories.add({
          'code': 'c_new',
          'label': body['label'] as String,
          'emoji': body['emoji'] as String,
        });
        data = categories.last;
      } else {
        attempts++;
        if (failCategoriesOnce && attempts == 1) {
          return http.Response(
            jsonEncode({
              'success': false,
              'error': {'code': 'INTERNAL', 'message': '加载失败'},
            }),
            503,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        data = categories;
      }
    } else if (request.url.path.contains('/subscription/subscriptions') &&
        request.method != 'GET') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      saved.add(body);
      data = {..._subscription(), ...body};
    } else {
      data = cinemaResponse(request);
    }
    return http.Response(
      jsonEncode({'success': true, 'data': data, 'error': null}),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  final session = WoSession(
    api: WoApi(ApiClient(httpClient: client, baseUrl: 'http://test')),
  );
  await session.load();
  return session;
}

Future<void> _open(
  WidgetTester tester,
  WoSession session, {
  Subscription? existing,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    WoScope(
      session: session,
      child: MaterialApp(
        theme: WoTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SubscriptionEditPage(existing: existing),
                ),
              ),
              child: const Text('打开订阅'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开订阅'));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );

void main() {
  test('旧订阅缺少新字段时默认软件/订阅并计入预算', () {
    final json = _subscription()
      ..remove('accounting_category')
      ..remove('exclude_from_budget');
    final sub = Subscription.fromJson(json);
    expect(sub.accountingCategory, 'subscription');
    expect(sub.excludeFromBudget, isFalse);
  });

  testWidgets('新增订阅可选择家庭分类并排除预算', (tester) async {
    final saved = <Map<String, dynamic>>[];
    final session = await _session(saved);
    await _open(tester, session);
    await tester.enterText(_field('名称'), '每月房租');
    await tester.enterText(_field('金额'), '100');
    await _tap(tester, find.byType(WoDropdownButtonFormField<String>));
    await _tap(tester, find.text('🏠 房租').last);
    await _tap(tester, find.text('计入月预算'));
    expect(find.text('仍计入本月支出，但不扣减预算'), findsOneWidget);
    await _tap(tester, find.text('添加'));
    expect(saved.single['accounting_category'], 'c_rent');
    expect(saved.single['exclude_from_budget'], isTrue);
    expect(saved.single['auto_record'], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑加载失败重试保留设置，关闭自动记账也不清空设置', (tester) async {
    final saved = <Map<String, dynamic>>[];
    final session = await _session(saved, failCategoriesOnce: true);
    await _open(
      tester,
      session,
      existing: Subscription.fromJson(_subscription()),
    );
    expect(find.text('分类加载失败，已保留当前设置'), findsOneWidget);
    await _tap(tester, find.text('重试'));
    expect(find.text('🏠 房租'), findsOneWidget);
    expect(find.text('仍计入本月支出，但不扣减预算'), findsOneWidget);
    await _tap(tester, find.text('到期自动记账'));
    expect(find.text('计入月预算'), findsNothing);
    await _tap(tester, find.text('保存'));
    expect(saved.single['auto_record'], isFalse);
    expect(saved.single['accounting_category'], 'c_rent');
    expect(saved.single['exclude_from_budget'], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('订阅中新增分类后立即选中并保存', (tester) async {
    final saved = <Map<String, dynamic>>[];
    final session = await _session(saved);
    await _open(
      tester,
      session,
      existing: Subscription.fromJson(_subscription()),
    );
    await _tap(tester, find.text('新增分类'));
    await tester.enterText(_field('分类名称'), '健身');
    await _tap(tester, find.text('保存分类'));
    expect(find.text('💰 健身'), findsOneWidget);
    await _tap(tester, find.text('计入月预算'));
    await _tap(tester, find.text('保存'));
    expect(saved.single['accounting_category'], 'c_new');
    expect(saved.single['exclude_from_budget'], isFalse);
    expect(tester.takeException(), isNull);
  });
}
