import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/features/home/home_page.dart';
import 'package:wo/features/plugins/accounting/accounting_page.dart';
import 'package:wo/theme/wo_theme.dart';
import 'package:wo/widgets/wo_card_trend.dart';

import 'support/cinema_fixtures.dart';

Map<String, Object?> _trend(List<Object> values) => {
      'label': '近7天每日支出',
      'unit': '元',
      'points': [
        for (var i = 0; i < values.length; i++)
          {'date': '2026-09-${23 + i}', 'value': values[i]},
      ],
    };

class _Fixture {
  _Fixture({this.cw = 2, this.ch = 2, this.hasTrend = true});

  final int cw;
  final int ch;
  final bool hasTrend;
  List<Object> values = [60, '125.50', 35, 210, 80, 145, 95];
  int loads = 0;
  Completer<void>? pending;
  bool fail = false;

  late final session = WoSession(
    api: WoApi(
      ApiClient(
        baseUrl: 'http://test',
        httpClient: MockClient((request) async {
          Object? data;
          if (request.url.path.endsWith('/me/bootstrap')) {
            loads++;
            if (pending != null) await pending!.future;
            if (fail) throw const SocketException('offline');
            data = {
              'user': cinemaUser,
              'current_family': cinemaFamily,
              'families': [cinemaFamily],
              'unread_count': 0,
              'installed_plugins': [
                {
                  ...cinemaInstalled('accounting'),
                  'layout': {'col': 0, 'row': 0, 'cw': cw, 'ch': ch},
                  'preview': {
                    'primary': '¥3,280',
                    'secondary': ch == 1 ? '本月支出' : '剩余 ¥1,720',
                    'color_token': 'money',
                    if (hasTrend) 'background_trend': _trend(values),
                  },
                },
              ],
            };
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
}

Future<void> _open(
  WidgetTester tester,
  _Fixture fixture, {
  bool dark = false,
  bool disableAnimations = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(360, 780));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await fixture.session.load();
  addTearDown(fixture.session.dispose);
  await tester.pumpWidget(
    WoScope(
      session: fixture.session,
      child: MaterialApp(
        theme: dark ? WoTheme.dark() : WoTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
            textScaler: const TextScaler.linear(1.3),
          ),
          child: child!,
        ),
        home: const RepaintBoundary(
          key: ValueKey('trend-capture'),
          child: HomePage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    final font = FontLoader('NotoSerifSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSerifSC.ttf'));
    await font.load();
    // 测试进程没有系统字体回退，使用内置中文字体避免截图出现方块。
    final body = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/NotoSerifSC.ttf'));
    await body.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  test('趋势兼容旧接口、Decimal 字符串与数字，日期不做时区转换', () {
    final old = PluginPreview.fromJson({'primary': '¥0'});
    expect(old.backgroundTrend, isNull);
    final parsed = BackgroundTrend.fromJson(_trend(['12.34', 56.78]));
    expect(parsed.points.map((p) => p.value), [12.34, 56.78]);
    expect(parsed.points.first.date, '2026-09-23');
  });

  for (final dark in [false, true]) {
    for (final size in [(2, 1), (2, 2), (4, 2)]) {
      testWidgets('真实首页趋势卡片 ${size.$1}×${size.$2} dark=$dark', (tester) async {
        final fixture = _Fixture(cw: size.$1, ch: size.$2);
        await _open(tester, fixture, dark: dark);
        expect(find.byType(WoCardTrend), findsOneWidget);
        expect(find.text('¥3,280'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (Platform.environment['WO_TREND_SCREENSHOT'] == '1') {
          await tester.runAsync(
            () => precacheImage(
              const AssetImage('assets/images/sunset-cinema.png'),
              tester.element(find.byType(HomePage)),
            ),
          );
          await tester.pumpAndSettle();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('trend-capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              'build/card-trend-qa/${dark ? "dark" : "light"}-${size.$1}x${size.$2}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        // 背景不能阻止首页长按进入编辑态。
        await tester.longPress(find.text('¥3,280'));
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.aspect_ratio), findsOneWidget);
        expect(find.byType(WoCardTrend), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final reduceMotion in [false, true]) {
    testWidgets('记账返回刷新且保留原卡片 reduceMotion=$reduceMotion', (tester) async {
      final fixture = _Fixture();
      await _open(tester, fixture, disableAnimations: reduceMotion);
      final old = tester.widget<WoCardTrend>(find.byType(WoCardTrend)).trend;
      await tester.tap(find.text('¥3,280'));
      await tester.pumpAndSettle();
      expect(find.byType(AccountingPage), findsOneWidget);
      final previousLoads = fixture.loads;
      fixture.pending = Completer<void>();
      fixture.values = [0, 0, 0, 0, 0, 0, '99.99'];
      Navigator.of(tester.element(find.byType(AccountingPage))).pop();
      await tester.pumpAndSettle();
      expect(fixture.loads, previousLoads + 1);
      expect(
        tester.widget<WoCardTrend>(find.byType(WoCardTrend)).trend,
        same(old),
      );
      expect(find.text('¥3,280'), findsOneWidget);
      fixture.pending!.complete();
      await tester.pumpAndSettle();
      final updated =
          tester.widget<WoCardTrend>(find.byType(WoCardTrend)).trend;
      expect(updated.points.last.value, 99.99);
      fixture.fail = true;
      await fixture.session.refresh();
      await tester.pumpAndSettle();
      expect(
        tester.widget<WoCardTrend>(find.byType(WoCardTrend)).trend,
        same(updated),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('全零趋势正常绘制，旧接口仍可正常展示卡片', (tester) async {
    final zero = _Fixture()..values = List.filled(7, 0);
    await _open(tester, zero);
    expect(find.byType(WoCardTrend), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    final old = _Fixture(hasTrend: false);
    await _open(tester, old);
    expect(find.byType(WoCardTrend), findsNothing);
    expect(find.text('¥3,280'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
