// 已准备；未执行Dart/Flutter/SDK，不代表原生前台或系统通知实测。
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/local/local_api.dart';
import 'package:wo/local/local_foreground_reminders.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/calendar_routes.dart';
import 'package:wo/features/messages/messages_page.dart';

class _DelayedBootstrapApi extends WoApi {
  _DelayedBootstrapApi() : super(ApiClient());
  final requests = <Completer<Bootstrap>>[];
  @override bool get isLocal => true;
  @override Future<Bootstrap> bootstrap() {
    final request = Completer<Bootstrap>(); requests.add(request); return request.future;
  }
}

class _DelayedMessagesApi extends WoApi {
  _DelayedMessagesApi(this.boot) : super(ApiClient());
  final Bootstrap boot;
  final requests = <Completer<List<WoNotification>>>[];
  @override bool get isLocal => true;
  @override Future<Bootstrap> bootstrap() async => boot;
  @override Future<List<WoNotification>> notifications({int limit = 50}) {
    final request = Completer<List<WoNotification>>(); requests.add(request); return request.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  late Directory directory; late LocalStore store; late LocalApi api;
  late DateTime clock; late String fid;
  Future<List<Json>> notifications() async => [for (final row in
    (await api.request('GET', '/notifications')).data as List) Json.from(row as Map)];
  Future<Json> bootstrap() async => Json.from((await api.request('GET', '/me/bootstrap')).data as Map);
  Future<void> notice(String id, {Object? recipients, String created = '2026-11-20T00:00:00Z'}) async {
    await store.patch(fid, '/families/$fid/notifications', id, {
      'type': 'calendar_due', 'title': id, 'body': '本地合成通知', 'created_at': created,
      'status': 'pending_local_delivery', 'recipient_ids': recipients ?? [store.deviceId],
    });
  }
  Future<void> install(String plugin) async { await store.patch(fid, '/families/$fid/installed', plugin,
    {'plugin_id': plugin, 'enabled': true}); }
  Future<void> reopen() async {
    await store.close(); store = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/db.sqlite');
    api = LocalApi(store, now: () => clock); await api.initialize();
  }
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wo-notification-delivery-');
    store = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/db.sqlite');
    clock = DateTime.utc(2026, 11, 20, 12); api = LocalApi(store, now: () => clock);
    await api.initialize(); fid = api.familyId!;
  });
  tearDown(() async { await store.close(); await directory.delete(recursive: true); });

  test('真实已读时间一次写入、重开不漂移、私有标记不进入peer日志', () async {
    await notice('one'); final before = await store.vector(fid);
    await api.request('PATCH', '/notifications/one/read');
    final first = (await notifications()).single; expect(first['read_at'], clock.toIso8601String());
    clock = clock.add(const Duration(days: 2)); await api.request('PATCH', '/notifications/one/read');
    await reopen(); expect((await notifications()).single['read_at'], first['read_at']);
    expect((await bootstrap())['unread_count'], 0); expect(await store.vector(fid), before);
  });
  test('旧bool已读不伪造时间，模型和角标仍已读', () async {
    await notice('legacy'); await store.setPrivate('notification-read:$fid:legacy', true);
    final row = (await notifications()).single;
    expect(row['is_read'], true); expect(row['read_at'], isNull);
    expect(WoNotification.fromJson(row).isRead, true); expect((await bootstrap())['unread_count'], 0);
    expect((await api.request('POST', '/notifications/read-all')).data, {'marked': 0});
    expect(await store.privateValue('notification-read:$fid:legacy'), true);
  });
  test('收件人缺失/错误类型/混入非字符串均不向全家兜底展示', () async {
    await notice('valid'); await notice('outside', recipients: ['another-member']);
    await notice('bad-type', recipients: 'everyone'); await notice('bad-item', recipients: [store.deviceId, 42]);
    await notice('missing'); await store.patch(fid, '/families/$fid/notifications', 'missing', {'recipient_ids': null});
    expect((await notifications()).map((row) => row['id']), ['valid']);
    expect((await bootstrap())['unread_count'], 1);
    await expectLater(api.request('PATCH', '/notifications/missing/read'), throwsA(isA<ApiException>()));
  });
  test('全部已读在单事务失败回滚，不留下部分已读', () async {
    await notice('a', created: '2026-11-20T02:00:00Z'); await notice('b');
    await store.db.execute("CREATE TRIGGER reject_read BEFORE INSERT ON meta WHEN NEW.key = 'private:notification-read:$fid:b' BEGIN SELECT RAISE(ABORT, 'synthetic read failure'); END");
    await expectLater(api.request('POST', '/notifications/read-all'), throwsA(anything));
    expect(await store.privateValue('notification-read:$fid:a'), isNull);
    expect((await bootstrap())['unread_count'], 2);
    await store.db.execute('DROP TRIGGER reject_read');
    expect((await api.request('POST', '/notifications/read-all')).data, {'marked': 2});
    expect((await notifications()).map((row) => row['read_at']).toSet(), {clock.toIso8601String()});
  });
  test('本地到期消息重开可读，隐藏后不因前台重算重复生回', () async {
    await install('calendar');
    await CalendarRoutes(store, now: () => clock).request('POST', fid, ['calendar', 'items'],
      body: {'title': '今天', 'event_date': '2026-11-20', 'notify_enabled': true});
    expect(await LocalForegroundReminders(store, now: () => clock).run([fid]), true);
    final id = (await notifications()).single['id']; await reopen();
    expect((await notifications()).single['id'], id);
    await api.request('DELETE', '/notifications/$id');
    expect(await LocalForegroundReminders(store, now: () => clock).run([fid]), false);
    await reopen(); expect(await notifications(), isEmpty); expect((await bootstrap())['unread_count'], 0);
  });
  test('一个插件部分提交后失败仍触发变更，其它已启用插件继续', () async {
    await install('anniversary'); await install('calendar'); final calls = <String>[];
    final reminders = LocalForegroundReminders(store, processors: {
      'anniversary': (_) async { calls.add('anniversary'); await notice('committed'); throw StateError('合成无效农历日期'); },
      'calendar': (_) async { calls.add('calendar'); return 0; },
      'plant': (_) async { calls.add('plant'); return 0; },
    });
    expect(await reminders.run([fid]), true); expect(calls, ['anniversary', 'calendar']);
    expect((await notifications()).single['id'], 'committed');
  });
  test('禁用插件及退到后台后不开始后续处理器', () async {
    await install('anniversary'); await install('calendar'); await install('plant');
    await store.patch(fid, '/families/$fid/installed', 'plant', {'enabled': false});
    var active = true; var plantCalls = 0; final calls = <String>[];
    final reminders = LocalForegroundReminders(store, processors: {
      'anniversary': (_) async { calls.add('anniversary'); active = false; return 0; },
      'calendar': (_) async { calls.add('calendar'); return 0; },
      'plant': (_) async { plantCalls++; return 0; },
    });
    expect(await reminders.run([fid], isActive: () => active), false);
    expect(calls, ['anniversary']);
    active = true; calls.clear();
    await LocalForegroundReminders(store, processors: {'plant': (_) async { plantCalls++; return 0; }}).run([fid]);
    expect(plantCalls, 0);
  });
  testWidgets('消息列表静默刷新保持已有行，晚到旧请求不能恢复旧未读行', (tester) async {
    final delayed = _DelayedMessagesApi(Bootstrap.fromJson(await bootstrap()));
    final session = WoSession(api: delayed);
    await tester.pumpWidget(WoScope(session: session, child: const MaterialApp(home: MessagesPage())));
    session.requestMessagesRefresh(); await tester.pump();
    delayed.requests[1].complete([const WoNotification(id: 'one', type: 'calendar_due',
      title: '最新已读消息', body: '合成正文', iconEmoji: '🔔', read: true)]);
    await tester.pump(); expect(find.text('最新已读消息'), findsOneWidget);
    delayed.requests[0].complete([const WoNotification(id: 'one', type: 'calendar_due',
      title: '过时未读消息', body: '合成正文', iconEmoji: '🔔')]);
    await tester.pump(); expect(find.text('过时未读消息'), findsNothing);
    session.requestMessagesRefresh(); await tester.pump();
    expect(find.text('最新已读消息'), findsOneWidget);
    delayed.requests[2].completeError(StateError('合成刷新失败')); await tester.pump();
    expect(find.text('最新已读消息'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink()); session.dispose();
  });
  test('较慢旧bootstrap不能覆盖新已读角标，也不能提前清loading', () async {
    final boot = await bootstrap(); final delayed = _DelayedBootstrapApi(); final session = WoSession(api: delayed);
    final older = session.load(), newer = session.load();
    delayed.requests[0].complete(Bootstrap.fromJson({...boot, 'unread_count': 7})); await older;
    expect(session.loading, true); expect(session.bootstrap, isNull);
    delayed.requests[1].complete(Bootstrap.fromJson({...boot, 'unread_count': 0})); await newer;
    expect(session.unreadCount, 0); expect(session.loading, false);
    final lateOld = session.load(), latest = session.load();
    delayed.requests[3].complete(Bootstrap.fromJson({...boot, 'unread_count': 1})); await latest;
    delayed.requests[2].complete(Bootstrap.fromJson({...boot, 'unread_count': 9})); await lateOld;
    expect(session.unreadCount, 1); session.dispose();
  });
}
