import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/features/plugins/accounting/accounting_entry_sheet.dart';
import 'package:wo/theme/wo_theme.dart';

import 'support/cinema_fixtures.dart';

Future<void> _open(
  WidgetTester tester,
  List<Map<String, dynamic>> saved, {
  Expense? existing,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final session = WoSession(
    api: WoApi(
      ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          Object? data;
          if (request.url.path.contains('/accounting/transactions')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            saved.add(body);
            data = {'id': existing?.id ?? 'expense-new', ...body};
          } else {
            data = cinemaResponse(request);
          }
          return http.Response(
            jsonEncode({'success': true, 'data': data}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    ),
  );
  await session.load();
  addTearDown(session.dispose);
  await tester.pumpWidget(
    WoScope(
      session: session,
      child: MaterialApp(
        theme: WoTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showExpenseEntrySheet(
                context,
                categories: const [ExpenseCategory('dining', '餐饮', '🍜')],
                existing: existing,
              ),
              child: const Text('打开记账'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开记账'));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('金额与备注切换键盘，保留算式和备注并支持收起后保存', (tester) async {
    final saved = <Map<String, dynamic>>[];
    await _open(tester, saved);
    expect(find.text('AC'), findsOneWidget);
    expect(tester.testTextInput.isVisible, isFalse);
    for (final key in ['1', '2', '+', '3']) {
      await _tap(tester, find.text(key));
    }
    expect(find.text('12 + 3'), findsOneWidget);

    await _tap(tester, find.byType(TextField));
    expect(find.text('AC'), findsNothing);
    expect(tester.testTextInput.isVisible, isTrue);
    // 模拟手机系统输入法占用底部空间，表单不能溢出。
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '午餐');
    expect(tester.takeException(), isNull);

    await _tap(tester, find.text('¥'));
    expect(tester.testTextInput.isVisible, isFalse);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.text('AC'), findsOneWidget);
    expect(find.text('12 + 3'), findsOneWidget);
    expect(find.text('午餐'), findsOneWidget);
    await _tap(tester, find.text('='));
    expect(find.text('15'), findsOneWidget);

    await _tap(tester, find.byTooltip('收起数字键盘'));
    expect(find.text('AC'), findsNothing);
    await _tap(tester, find.text('完成'));
    expect(saved.single['amount'], 15);
    expect(saved.single['note'], '午餐');
    expect(find.text('记一笔'), findsNothing);
  });

  testWidgets('编辑时可直接在备注输入状态保存，完成输入不会自动展开数字键盘', (tester) async {
    final saved = <Map<String, dynamic>>[];
    await _open(
      tester,
      saved,
      existing: const Expense(
        id: 'expense-old',
        familyId: 'cinema-family',
        amount: 42.5,
        category: 'dining',
        note: '原备注',
      ),
    );
    await _tap(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), '新备注');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('AC'), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
    await _tap(tester, find.byType(TextField));
    expect(tester.testTextInput.isVisible, isTrue);
    await _tap(tester, find.text('保存'));
    expect(saved.single['amount'], 42.5);
    expect(saved.single['note'], '新备注');
    expect(find.text('编辑支出'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
