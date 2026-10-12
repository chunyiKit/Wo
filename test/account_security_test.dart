import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/features/auth/recovery_page.dart';
import 'package:wo/theme/wo_theme.dart';

const user = WoUser(
  id: 'test-user',
  username: 'test',
  displayName: '测试',
  avatarEmoji: '👤',
  level: 1,
);
const securityBootstrap = Bootstrap(
  user: user,
  currentFamily: null,
  families: [],
  installedPlugins: [],
  unreadCount: 0,
);
const auth =
    AuthResult(user: user, token: 'synthetic-test-token', isNew: false);

http.Response utf8Response(String body, int status) => http.Response(
      body,
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

class SecurityApi extends WoApi {
  SecurityApi() : super(ApiClient(baseUrl: 'http://test'));
  Completer<AuthResult>? loginPending;
  Completer<Bootstrap>? loadPending;
  Completer<void>? resetPending;
  Completer<Map<String, dynamic>>? enrollPending;
  bool failAll = false;
  int logins = 0;
  int resets = 0;
  int enrollments = 0;
  String? discarded;

  @override
  Future<AuthResult> login(String phone, String password) {
    logins++;
    return loginPending?.future ?? Future.value(auth);
  }

  @override
  Future<Bootstrap> bootstrap() =>
      loadPending?.future ?? Future.value(securityBootstrap);
  @override
  Future<void> logout() async {}
  @override
  Future<void> logoutAll() async {
    if (failAll) throw NetworkException('请求超时，请重试');
  }

  @override
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {}
  @override
  Future<void> discardLoginToken(String token) async {
    discarded = token;
  }

  @override
  Future<Map<String, dynamic>> createRecoveryCode(String password) {
    enrollments++;
    return enrollPending?.future ??
        Future.value({
          'recovery_code': 'synthetic-one-time-code',
          'expires_at': '2027-10-12',
        });
  }

  @override
  Future<void> resetPassword({
    required String phone,
    required String recoveryCode,
    required String newPassword,
  }) {
    resets++;
    return resetPending?.future ?? Future.value();
  }
}

Future<GoRouter> showPage(
  WidgetTester tester,
  WoSession session, {
  bool enroll = false,
}) async {
  final router = GoRouter(
    initialLocation: '/security',
    routes: [
      GoRoute(
        path: '/security',
        builder: (_, __) => RecoveryPage(enroll: enroll),
      ),
      GoRoute(
        path: '/login',
        builder: (_, __) => const Scaffold(body: Text('登录页')),
      ),
    ],
  );
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
  return router;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('改密与全部撤销清 token、身份和首屏缓存', () async {
    final api = SecurityApi();
    final session = WoSession(api: api);
    await session.login('13900000000', 'synthetic-password');
    await session.changePassword('synthetic-password', 'new-password');
    expect(session.isLoggedIn, isFalse);
    expect(session.bootstrap, isNull);
    expect(api.authToken, isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getString('wo.token'),
      isNull,
    );
    await session.login('13900000000', 'new-password');
    await session.logout(all: true);
    expect(session.isLoggedIn, isFalse);
    session.dispose();
  });

  test('全部撤销网络失败保留登录状态供重试', () async {
    final api = SecurityApi()..failAll = true;
    final session = WoSession(api: api);
    await session.login('13900000000', 'synthetic-password');
    await expectLater(
      session.logout(all: true),
      throwsA(isA<NetworkException>()),
    );
    expect(session.isLoggedIn, isTrue);
    api.failAll = false;
    await session.logout(all: true);
    expect(session.isLoggedIn, isFalse);
    session.dispose();
  });

  test('迟到 bootstrap 不恢复退出后的身份', () async {
    final api = SecurityApi();
    final session = WoSession(api: api);
    await session.login('13900000000', 'synthetic-password');
    api.loadPending = Completer<Bootstrap>();
    final loading = session.load();
    await session.logout();
    api.loadPending!.complete(securityBootstrap);
    await loading;
    expect(session.bootstrap, isNull);
    expect(session.isLoggedIn, isFalse);
    session.dispose();
  });

  test('重复登录只发一次，中断后的迟到 token 被撤销', () async {
    final api = SecurityApi()..loginPending = Completer<AuthResult>();
    final session = WoSession(api: api);
    final login = session.login('13900000000', 'synthetic-password');
    final failed = expectLater(login, throwsStateError);
    await expectLater(
      session.login('13900000000', 'synthetic-password'),
      throwsStateError,
    );
    await session.logout();
    api.loginPending!.complete(auth);
    await failed;
    expect(api.logins, 1);
    expect(api.discarded, auth.token);
    expect(session.isLoggedIn, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getString('wo.token'),
      isNull,
    );
    session.dispose();
  });

  test('任意受保护请求会话失效触发统一清理', () async {
    final httpClient = MockClient(
      (request) async => utf8Response(
        jsonEncode({
          'success': false,
          'error': {
            'code': 'UNAUTHORIZED',
            'message': '登录失效',
            'details': {'session_invalid': true},
          },
        }),
        401,
      ),
    );
    final client = ApiClient(baseUrl: 'http://test', httpClient: httpClient);
    final api = WoApi(client);
    final session = WoSession(api: api);
    SharedPreferences.setMockInitialValues(
      {'wo.token': 'synthetic-test-token'},
    );
    await session.restore();
    await expectLater(api.me(), throwsA(isA<ApiException>()));
    expect(session.isLoggedIn, isFalse);
    expect(api.authToken, isEmpty);
    session.dispose();
    client.close();
  });

  test('原密码错误不清登录态，旧请求失效不清新令牌', () async {
    final reply = Completer<http.Response>();
    final client = ApiClient(
      baseUrl: 'http://test',
      authToken: 'old-token',
      httpClient: MockClient((_) => reply.future),
    );
    int invalidations = 0;
    client.onSessionInvalid = () async {
      invalidations++;
    };
    final request = client.get('/me');
    final failed = expectLater(request, throwsA(isA<ApiException>()));
    client.authToken = 'new-token';
    reply.complete(
      utf8Response(
        jsonEncode({
          'success': false,
          'error': {
            'code': 'UNAUTHORIZED',
            'details': {'session_invalid': true},
          },
        }),
        401,
      ),
    );
    await failed;
    expect(invalidations, 0);
    client.close();
    final wrongPasswordClient = ApiClient(
      baseUrl: 'http://test',
      authToken: 'new-token',
      httpClient: MockClient(
        (_) async => utf8Response(
          jsonEncode({
            'success': false,
            'error': {'code': 'UNAUTHORIZED', 'message': '原密码错误'},
          }),
          401,
        ),
      ),
    );
    wrongPasswordClient.onSessionInvalid = () async {
      invalidations++;
    };
    await expectLater(
      wrongPasswordClient.post('/auth/change-password'),
      throwsA(isA<ApiException>()),
    );
    expect(invalidations, 0);
    wrongPasswordClient.close();
  });

  testWidgets('生成恢复码重复提交受限，离开页面后迟到响应安全', (tester) async {
    final api = SecurityApi()
      ..enrollPending = Completer<Map<String, dynamic>>();
    final session = WoSession(api: api);
    final router = await showPage(tester, session, enroll: true);
    await tester.enterText(find.byType(TextField).first, 'synthetic-password');
    await tester.pump();
    await tester.tap(find.text('生成 / 替换恢复码'));
    await tester.pump();
    expect(api.enrollments, 1);
    expect(find.text('处理中…'), findsOneWidget);
    router.go('/login');
    await tester.pumpAndSettle();
    api.enrollPending!.complete({
      'recovery_code': 'synthetic-one-time-code',
      'expires_at': '2027-10-12',
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    session.dispose();
  });

  testWidgets('找回表单校验确认密码，超时可重试，不重复发送', (tester) async {
    final api = SecurityApi()..resetPending = Completer<void>();
    final session = WoSession(api: api);
    final router = await showPage(tester, session);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '13900000000');
    await tester.enterText(fields.at(1), 'synthetic-code');
    await tester.enterText(fields.at(2), 'new-password');
    await tester.enterText(fields.at(3), 'mismatch');
    await tester.pump();
    await tester.ensureVisible(find.text('重置密码'));
    await tester.tap(find.text('重置密码'));
    expect(api.resets, 0);
    await tester.enterText(fields.at(3), 'new-password');
    await tester.pump();
    await tester.ensureVisible(find.text('重置密码'));
    await tester.tap(find.text('重置密码'));
    await tester.pump();
    expect(api.resets, 1);
    api.resetPending!.completeError(NetworkException('请求超时，请重试'));
    await tester.pumpAndSettle();
    expect(find.text('请求超时，请重试'), findsOneWidget);
    api.resetPending = Completer<void>();
    await tester.ensureVisible(find.text('重置密码'));
    await tester.tap(find.text('重置密码'));
    await tester.pump();
    expect(api.resets, 2);
    router.go('/login');
    await tester.pumpAndSettle();
    api.resetPending!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(session.isLoggedIn, isFalse);
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    session.dispose();
  });
}
