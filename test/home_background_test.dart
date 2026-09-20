import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/features/home/home_page.dart';
import 'package:wo/features/home/home_background_page.dart';
import 'package:wo/features/home/family_home_background.dart';
import 'package:wo/theme/wo_theme.dart';

import 'support/cinema_fixtures.dart';

class _Api extends WoApi {
  _Api({this.role = 'owner', this.background})
      : super(ApiClient(baseUrl: 'http://test'));
  final String role;
  String? background;
  bool failUpload = false;
  int uploads = 0;
  Family get family => Family.fromJson(
        {...cinemaFamily, 'my_role': role, 'background_url': background},
      );

  @override
  Future<Bootstrap> bootstrap() async => Bootstrap(
        user: WoUser.fromJson(cinemaUser),
        currentFamily: family,
        families: [family],
        installedPlugins: [
          InstalledPlugin.fromJson(cinemaInstalled('subscription')),
        ],
        unreadCount: 0,
      );

  @override
  Future<Family> uploadFamilyBackground(
    String familyId, {
    required List<int> bytes,
  }) async {
    expect(familyId, 'cinema-family');
    expect(bytes, isNotEmpty);
    uploads++;
    if (failUpload) throw NetworkException('上传失败，请重试');
    background = '/api/v1/families/cinema-family/background?v=$uploads';
    return family;
  }

  @override
  Future<Family> resetFamilyBackground(String familyId) async {
    background = null;
    return family;
  }
}

Future<WoSession> _session(_Api api) async {
  final session = WoSession(api: api);
  await session.load();
  return session;
}

Widget _app(
  WoSession session,
  Widget home, {
  bool dark = false,
  double textScale = 1,
}) =>
    WoScope(
      session: session,
      child: MaterialApp(
        theme: dark ? WoTheme.dark() : WoTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: const EdgeInsets.only(top: 24),
            disableAnimations: true,
          ),
          child: child!,
        ),
        home: RepaintBoundary(key: const ValueKey('capture-home'), child: home),
      ),
    );

Future<void> _editor(WidgetTester tester, WoSession session) async {
  await tester.pumpWidget(
    _app(
      session,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            child: const Text('打开背景'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => HomeBackgroundPage(
                  family: session.currentFamily!,
                  pickImage: () async => (await rootBundle.load(
                    'assets/images/sunset-cinema.png',
                  ))
                      .buffer
                      .asUint8List(),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开背景'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('NotoSerifSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSerifSC.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final bodyFont = Platform.environment['WO_QA_BODY_FONT'];
    if (bodyFont != null) {
      final body = FontLoader('Roboto')
        ..addFont(
          File(bodyFont)
              .readAsBytes()
              .then((bytes) => ByteData.sublistView(bytes)),
        );
      await body.load();
    }
  });
  for (final dark in [false, true]) {
    testWidgets('首页半高布局及背景入口 ${dark ? "深色" : "浅色"}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = await _session(_Api());
      await tester.pumpWidget(_app(session, const HomePage(), dark: dark));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('home-hero'))).height,
        229,
      );
      expect(tester.getTopLeft(find.text('小家的日常')).dy, lessThan(320));
      expect(find.byTooltip('更换首页背景'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['WO_HOME_SCREENSHOT'] == '1') {
        await tester.runAsync(
          () => precacheImage(
            const AssetImage('assets/images/sunset-cinema.png'),
            tester.element(find.byType(HomePage)),
          ),
        );
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture-home')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/home-background-qa/home-${dark ? "dark" : "light"}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byTooltip('更换首页背景'));
      await tester.pumpAndSettle();
      expect(find.text('首页背景'), findsOneWidget);
    });
  }

  for (final role in ['owner', 'member']) {
    testWidgets('小屏大字布局正常，背景入口遵守权限 $role', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = await _session(_Api(role: role));
      await tester.pumpWidget(_app(session, const HomePage(), textScale: 1.3));
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('更换首页背景'),
        role == 'owner' ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('上传失败保留预览可重试，保存即同步家庭背景', (tester) async {
    final api = _Api()..failUpload = true;
    final session = await _session(api);
    await _editor(tester, session);
    await tester.tap(find.text('从相册选择'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FamilyHomeBackground>(find.byType(FamilyHomeBackground))
          .preview,
      isNotNull,
    );
    await tester.tap(find.text('保存背景'));
    await tester.pumpAndSettle();
    expect(find.text('上传失败，请重试'), findsOneWidget);
    expect(session.currentFamily!.backgroundUrl, isNull);
    api.failUpload = false;
    await tester.tap(find.text('保存背景'));
    await tester.pumpAndSettle();
    expect(find.text('打开背景'), findsOneWidget);
    expect(session.currentFamily!.backgroundUrl, contains('v=2'));
    expect(
      session.families.single.backgroundUrl,
      session.currentFamily!.backgroundUrl,
    );
    expect(session.bootstrap!.installedPlugins, hasLength(1));
  });

  testWidgets('恢复默认背景同步到家庭快照', (tester) async {
    final session = await _session(
      _Api(background: '/api/v1/families/cinema-family/background?v=1'),
    );
    await _editor(tester, session);
    await tester.tap(find.text('恢复默认背景'));
    await tester.pumpAndSettle();
    expect(session.currentFamily!.backgroundUrl, isNull);
    expect(find.text('打开背景'), findsOneWidget);
  });
}
