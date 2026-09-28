import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/features/family/pet_profile_edit_page.dart';
import 'package:wo/features/home/home_page.dart';
import 'package:wo/features/plugins/anniversary/anniversary_edit_page.dart';
import 'package:wo/features/plugins/calendar/calendar_edit_page.dart';
import 'package:wo/features/plugins/expiry/expiry_page.dart';
import 'package:wo/features/plugins/memory/memory_edit_page.dart';
import 'package:wo/features/plugins/pet/pet_settings_page.dart';
import 'package:wo/features/plugins/retirement/plan_edit_page.dart';
import 'package:wo/features/plugins/subscription/subscription_page.dart';
import 'package:wo/navigation/wo_router.dart';
import 'package:wo/navigation/wo_routes.dart';
import 'package:wo/theme/wo_theme.dart';

import 'support/cinema_fixtures.dart';

Future<WoSession> _session() async {
  final client = MockClient((request) async {
    final path = request.url.path;
    final Object data;
    if (path.endsWith('/me/bootstrap')) {
      data = {
        'user': cinemaUser,
        'current_family': cinemaFamily,
        'families': [cinemaFamily],
        'installed_plugins': [],
        'unread_count': 0,
      };
    } else if (path.endsWith('/record-types')) {
      data = [
        {
          'id': 't1',
          'family_id': 'cinema-family',
          'name': '驱虫',
          'emoji': '🛡️',
          'data_kind': 'general',
        },
      ];
    } else if (path.endsWith('/plan')) {
      data = <String, Object?>{};
    } else if (['/members', '/categories', '/plans'].any(path.endsWith)) {
      data = [];
    } else {
      throw StateError('未提供测试响应：$path');
    }
    return http.Response(
      jsonEncode({'success': true, 'data': data}),
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

Future<void> _openPage(WidgetTester tester, Widget page) async {
  final session = await _session();
  final router = buildRouter()..go(WoRoutes.home);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    WoScope(
      session: session,
      child: MaterialApp.router(
        theme: WoTheme.light(),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  Navigator.of(tester.element(find.byType(HomePage))).push<void>(
    MaterialPageRoute(builder: (_) => page),
  );
  await tester.pumpAndSettle();
}

Future<void> _back(WidgetTester tester, {required bool predictive}) async {
  if (predictive) {
    for (final call in [
      const MethodCall('startBackGesture', {
        'touchOffset': [5.0, 300.0],
        'progress': 0.0,
        'swipeEdge': 0,
      }),
      const MethodCall('commitBackGesture'),
    ]) {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(call),
        (_) {},
      );
      await tester.pump();
    }
  } else {
    await tester.binding.handlePopRoute();
  }
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  final cases = <(String, Widget, String)>[
    ('宠物生日', const PetProfileEditPage(), '生日'),
    ('宠物到家日期', const PetProfileEditPage(), '到家日期'),
    ('退休计划', const PlanEditPage(), '选择日期'),
    ('回忆', const MemoryEditPage(), '日期'),
    ('纪念日', const AnniversaryEditPage(), '日期'),
    ('到期管家', const ExpiryEditPage(), '到期日'),
    ('订阅管家', const SubscriptionEditPage(), '下次扣费日'),
    ('家历', const CalendarEditPage(), '选日期'),
    (
      '宠物照护计划',
      PetSettingsPage(
        pet: Pet.fromJson({
          'id': 'p1',
          'family_id': 'cinema-family',
          'name': '团子',
          'emoji': '🐈',
        }),
      ),
      '下次日期',
    ),
  ];

  for (final (name, page, label) in cases) {
    testWidgets('$name：日期弹窗优先响应返回且不丢失表单', (tester) async {
      await _openPage(tester, page);
      final nested = page is PetSettingsPage;
      if (nested) await _tap(tester, find.text('新建'));
      final field = find.byType(TextField).first;
      await tester.ensureVisible(field);
      await tester.enterText(field, '123');
      final draft = tester.widget<TextField>(field).controller!;
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      // 同时覆盖 Android 预测式手势和传统返回按键。
      for (final predictive in [true, false]) {
        await _tap(tester, find.text(label));
        expect(find.byType(DatePickerDialog), findsOneWidget);
        final initial = tester
            .widget<DatePickerDialog>(find.byType(DatePickerDialog))
            .initialDate;
        await _back(tester, predictive: predictive);
        expect(find.byType(DatePickerDialog), findsNothing);
        expect(find.byType(page.runtimeType), findsOneWidget);
        expect(draft.text, '123');
        if (nested) expect(find.text('新建照护计划'), findsOneWidget);

        // 返回与取消按钮效果相同，重新打开仍是原日期。
        await _tap(tester, find.text(label));
        expect(
          tester
              .widget<DatePickerDialog>(find.byType(DatePickerDialog))
              .initialDate,
          initial,
        );
        await _tap(tester, find.text('Cancel'));
        expect(find.byType(DatePickerDialog), findsNothing);
      }
      if (nested) {
        await _back(tester, predictive: true);
        expect(find.text('新建照护计划'), findsNothing);
        expect(find.byType(PetSettingsPage), findsOneWidget);
      }
      await _back(tester, predictive: true);
      expect(find.byType(page.runtimeType), findsNothing);
      expect(find.byType(HomePage), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('家历时间选择器优先响应返回且保留原时间', (tester) async {
    await _openPage(
      tester,
      CalendarEditPage(
        existing: CalendarItem(
          id: 'c1',
          familyId: 'cinema-family',
          title: '未保存日程',
          emoji: '📅',
          done: false,
          eventDate: DateTime.now(),
          allDay: false,
          startMinute: 9 * 60,
        ),
      ),
    );
    for (final predictive in [true, false]) {
      await _tap(tester, find.byIcon(Icons.schedule));
      expect(find.byType(TimePickerDialog), findsOneWidget);
      expect(
        tester
            .widget<TimePickerDialog>(find.byType(TimePickerDialog))
            .initialTime,
        const TimeOfDay(hour: 9, minute: 0),
      );
      await _back(tester, predictive: predictive);
      expect(find.byType(TimePickerDialog), findsNothing);
      expect(find.byType(CalendarEditPage), findsOneWidget);
      expect(find.text('未保存日程'), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
