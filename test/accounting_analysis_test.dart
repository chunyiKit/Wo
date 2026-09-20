import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/features/plugins/accounting/accounting_analysis_view.dart';
import 'package:wo/features/plugins/accounting/accounting_page.dart';
import 'package:wo/features/plugins/accounting/expense_categories.dart';
import 'package:wo/widgets/wo_material_controls.dart';
import 'package:wo/theme/wo_theme.dart';

Expense _expense({
  required String id,
  required double amount,
  required String category,
  String? note,
}) =>
    Expense(
      id: id,
      familyId: 'f1',
      amount: amount,
      category: category,
      note: note,
      creatorName: '主理人',
      creatorEmoji: '👤',
      createdAt: DateTime(2026, 8, 20, 12),
    );

Map<String, dynamic> _expenseJson({
  required String id,
  required String amount,
  required String category,
  required String note,
}) =>
    {
      'id': id,
      'family_id': 'f1',
      'amount': amount,
      'category': category,
      'note': note,
      'exclude_from_budget': false,
      'created_by': 'u1',
      'creator_name': '主理人',
      'creator_emoji': '👤',
      'creator_avatar_url': null,
      'created_at': '2026-08-20T12:00:00Z',
    };

Map<String, dynamic> _envelope(Object? data) => {
      'success': true,
      'data': data,
      'error': null,
      'meta': null,
    };

Future<WoSession> _session({
  List<Map<String, dynamic>>? savedExpenses,
  bool failCategoryOnce = false,
}) async {
  final categories = [
    for (final c in expenseCategories)
      {'code': c.code, 'label': c.label, 'emoji': c.emoji},
  ];
  var categoryAttempts = 0;
  final client = MockClient((request) async {
    final path = request.url.path;
    Object? data;
    if (path.endsWith('/me/bootstrap')) {
      data = {
        'user': {
          'id': 'u1',
          'username': 'owner',
          'display_name': '主理人',
          'avatar_emoji': '👤',
        },
        'current_family': {
          'id': 'f1',
          'name': '我的家',
          'emoji': '🏡',
          'member_count': 1,
          'pet_count': 0,
          'my_role': 'owner',
          'my_unread_count': 0,
        },
        'families': [
          {
            'id': 'f1',
            'name': '我的家',
            'emoji': '🏡',
            'member_count': 1,
            'pet_count': 0,
            'my_role': 'owner',
            'my_unread_count': 0,
          },
        ],
        'installed_plugins': [],
        'unread_count': 0,
      };
    } else if (path.endsWith('/plugins/accounting/categories')) {
      if (request.method == 'POST') {
        categoryAttempts++;
        if (failCategoryOnce && categoryAttempts == 1) {
          return http.Response(
            jsonEncode({
              'success': false,
              'error': {'code': 'VALIDATION_ERROR', 'message': '新增失败，请重试'},
            }),
            422,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        categories.add({
          'code': 'c_travel',
          'label': payload['label'] as String,
          'emoji': payload['emoji'] as String,
        });
        data = categories.last;
      } else {
        data = categories;
      }
    } else if (path.endsWith('/plugins/accounting/summary')) {
      data = {
        'month_total': '150.00',
        'budget': null,
        'remaining': null,
        'budgeted_total': '150.00',
        'excluded_total': '0',
      };
    } else if (path.endsWith('/plugins/accounting/transactions') &&
        request.method == 'POST') {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      data = _expenseJson(
        id: 'new',
        amount: payload['amount'].toString(),
        category: payload['category'] as String,
        note: '',
      );
      savedExpenses?.add(data as Map<String, dynamic>);
    } else if (path.endsWith('/plugins/accounting/transactions')) {
      data = [
        ...?savedExpenses,
        _expenseJson(
          id: 'e1',
          amount: '70.00',
          category: 'dining',
          note: '午餐',
        ),
        _expenseJson(
          id: 'e2',
          amount: '30.00',
          category: 'dining',
          note: '晚餐',
        ),
        _expenseJson(
          id: 'e3',
          amount: '50.00',
          category: 'pet',
          note: '猫粮',
        ),
      ];
    } else {
      throw StateError('unexpected ${request.url}');
    }
    return http.Response(
      jsonEncode(_envelope(data)),
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

Widget _app(WoSession session) => WoScope(
      session: session,
      child: MaterialApp(theme: WoTheme.light(), home: const AccountingPage()),
    );

void main() {
  testWidgets('新增分类失败可重试，保存后自动选中并用于记账', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final saved = <Map<String, dynamic>>[];
    final session =
        await _session(savedExpenses: saved, failCategoryOnce: true);
    await tester.pumpWidget(_app(session));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(WoFloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();
    expect(find.text('请输入分类名称'), findsOneWidget);
    final name = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(name, '餐饮');
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();
    expect(find.text('分类名称已存在'), findsOneWidget);
    await tester.enterText(name, '旅行');
    await tester.tap(find.text('✈️'));
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();
    expect(find.text('新增失败，请重试'), findsOneWidget);
    expect(find.text('旅行'), findsOneWidget);
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('旅行'), findsOneWidget);
    await tester.tap(find.text('8'));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(saved.single['category'], 'c_travel');
    expect(find.textContaining('旅行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消记账后重新打开仍能选择已保存分类', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = await _session();
    await tester.pumpWidget(_app(session));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(WoFloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增分类'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '旅行',
    );
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('旅行'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(WoFloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('旅行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('custom categories remain separate from unknown categories', () {
    const travel = ExpenseCategory('c_travel', '旅行', '✈️');
    final result = buildCategoryExpenseBreakdown(
      [
        _expense(id: '1', amount: 80, category: travel.code),
        _expense(id: '2', amount: 20, category: 'unknown'),
      ],
      categories: [
        ...expenseCategories,
        travel,
      ],
    );
    expect(result.map((item) => item.category.label), ['旅行', '其他']);
    expect(result.first.fraction, 0.8);
    expect(
      categoryFor(travel.code, [...expenseCategories, travel]).emoji,
      '✈️',
    );
  });

  test('category breakdown totals amounts, counts, and fractions', () {
    final result = buildCategoryExpenseBreakdown([
      _expense(id: '1', amount: 70, category: 'dining'),
      _expense(id: '2', amount: 30, category: 'dining'),
      _expense(id: '3', amount: 50, category: 'pet'),
    ]);

    expect(result.map((item) => item.category.code), ['dining', 'pet']);
    expect(result.first.amount, 100);
    expect(result.first.count, 2);
    expect(result.first.fraction, closeTo(2 / 3, 0.0001));
    expect(result.last.fraction, closeTo(1 / 3, 0.0001));
  });

  testWidgets('analysis shows a pie and filters details by category',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = await _session();
    await tester.pumpWidget(_app(session));
    await tester.pumpAndSettle();

    await tester.tap(find.text('分析'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('accounting-analysis-pie')),
      findsOneWidget,
    );
    expect(find.textContaining('66.7%'), findsOneWidget);
    expect(find.textContaining('33.3%'), findsOneWidget);

    final petFilter = find.byKey(const ValueKey('analysis-category-pet'));
    await tester.scrollUntilVisible(
      petFilter,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(petFilter);
    await tester.pumpAndSettle();
    await tester.tap(petFilter);
    await tester.pumpAndSettle();
    expect(find.textContaining('猫粮'), findsOneWidget);
    expect(find.textContaining('午餐'), findsNothing);
    expect(find.textContaining('晚餐'), findsNothing);
  });
}
