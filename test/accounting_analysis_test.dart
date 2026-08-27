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

Future<WoSession> _session() async {
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
    } else if (path.endsWith('/plugins/accounting/summary')) {
      data = {
        'month_total': '150.00',
        'budget': null,
        'remaining': null,
        'budgeted_total': '150.00',
        'excluded_total': '0',
      };
    } else if (path.endsWith('/plugins/accounting/transactions')) {
      data = [
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
