import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' show DatabaseException;
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/local/local_backend.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/chat_routes.dart';

// 测试源码尚未执行。
void main() {
  sqfliteFfiInit();
  const fid = 'family';
  late Directory directory;
  late LocalStore a, b;
  late ChatRoutes routesA, routesB;
  late DateTime clock;
  Matcher error(int status) => throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', status));
  Future<LocalResult> call(ChatRoutes routes, String method, List<String> tail,
    {Json body = const {}, Json query = const {}}) async =>
    (await routes.request(method, fid, ['chat', ...tail], body: body, query: query))!;
  Future<Json> send(ChatRoutes routes, String client, String text) async => Json.from(
    (await call(routes, 'POST', ['messages'], body: {'client_id': client, 'body': text})).data as Map);
  Future<void> transfer(LocalStore from, LocalStore to) async {
    for (var round = 0; round < 100; round++) {
      final ops = await from.exportSince(fid, await to.vector(fid));
      if (ops.isEmpty) return;
      await to.merge(fid, ops);
    }
    fail('增量未结束');
  }
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wo-local-chat-');
    a = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/a.sqlite');
    b = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/b.sqlite');
    for (final destination in [a, b]) {
      for (final member in [a, b]) {
        await destination.patch(fid, '/families/$fid/members', member.deviceId, {
          'family_id': fid, 'user_id': member.deviceId, 'status': 'active', 'role': 'member',
          'display_name': member == a ? '甲' : '乙', 'avatar_emoji': '🐱',
          'avatar_url': '/local/avatar/${member.deviceId}?v=1',
        });
      }
    }
    clock = DateTime.utc(2026, 11, 20, 10);
    routesA = ChatRoutes(a, now: () => clock); routesB = ChatRoutes(b, now: () => clock);
  });
  tearDown(() async { await a.close(); await b.close(); await directory.delete(recursive: true); });

  test('稳定ID与独立UUIDv5向量一致，成员和家庭作用域互不碰撞', () {
    expect(ChatRoutes.messageId('family', 'actor', 'client'), 'a693553b-9e00-566b-8525-f7b50d7f99c3');
    expect(ChatRoutes.messageId('family', 'actor', 'client'), isNot(ChatRoutes.messageId('family', 'other', 'client')));
    expect(ChatRoutes.messageId('family', 'actor', 'client'), isNot(ChatRoutes.messageId('other', 'actor', 'client')));
  });
  test('并发重试只提交一条消息，重复client_id更换正文被拒绝', () async {
    final values = await Future.wait([send(routesA, 'same-client', '你好'), send(routesA, 'same-client', ' 你好 ')]);
    expect(values[0]['id'], values[1]['id']);
    expect((await routesA.snapshot(fid)).length, 1);
    final creation = (await a.exportSince(fid, {})).where((op) => (op['collection'] as String).endsWith('/chat/messages'));
    expect(creation.length, 1);
    await expectLater(send(routesA, 'same-client', '其他正文'), error(409));
    final other = await send(routesB, 'same-client', '不同成员');
    expect(other['id'], isNot(values[0]['id']));
  });
  test('重启从事实源恢复且投影真实头像，不虚报已送达', () async {
    final sent = await send(routesA, 'restart', '本机保存');
    expect(sent['delivery_status'], 'saved_local');
    expect(sent['sender_avatar_url'], '/local/avatar/${a.deviceId}?v=1');
    expect(ChatMessage.fromJson(sent).body, '本机保存');
    final device = a.deviceId;
    await a.close(); a = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/a.sqlite');
    routesA = ChatRoutes(a, now: () => clock);
    expect(a.deviceId, device); expect((await routesA.snapshot(fid)).single['id'], sent['id']);
    final retry = await send(routesA, 'restart', '本机保存');
    expect(retry['id'], sent['id']); expect((await routesA.snapshot(fid)).length, 1);
  });
  test('早时间补录与相同时间仍可分页读取，快照不受旧时间游标截断', () async {
    await send(routesA, 'later-a', '较晚甲'); await send(routesA, 'later-b', '较晚乙');
    clock = DateTime.utc(1999, 1, 1); final earlier = await send(routesA, 'earlier', '补录');
    final all = await routesA.snapshot(fid);
    expect(all.first['id'], earlier['id']); expect(all.length, 3);
    final page = await call(routesA, 'GET', ['messages'], query: {'limit': 1});
    final first = (page.data as List).single as Map;
    expect(first['id'], earlier['id']); expect(page.meta!['cursor'], isNotNull);
    final next = await call(routesA, 'GET', ['messages'], query: {'after_created_at': first['created_at'], 'after_id': first['id']});
    expect((next.data as List).length, 2);
    expect((await routesA.snapshot(fid)).first['body'], '补录');
  });
  test('本人撤回幂等，其他成员不能撤回，墓碑拒绝旧patch复活', () async {
    final sent = await send(routesA, 'withdraw', '可撤回正文'); await transfer(a, b);
    await expectLater(call(routesB, 'DELETE', ['messages', sent['id'] as String]), error(403));
    final old = (await a.exportSince(fid, {})).where((op) => op['id'] == sent['id']).toList();
    await call(routesA, 'DELETE', ['messages', sent['id'] as String]);
    await call(routesA, 'DELETE', ['messages', sent['id'] as String]);
    await transfer(a, b); await b.merge(fid, old);
    final withdrawn = (await routesB.snapshot(fid)).single;
    expect(withdrawn['id'], sent['id']); expect(withdrawn['retracted'], true); expect(withdrawn['body'], isNull);
    expect((await send(routesA, 'withdraw', '可撤回正文'))['retracted'], true);
    // 撤回是同步删除标记，不声称从既有日志/对方备份物理擦除正文。
    expect(LocalStore.canonical(await a.exportSince(fid, {})), contains('可撤回正文'));
  });
  test('成员状态只能写本人并可清空后重设，姓名头像实时投影', () async {
    await call(routesA, 'PUT', ['status'], body: {'emoji': '🍵', 'text': '休息'});
    expect((await routesA.statuses(fid)).single['created_by'], a.deviceId);
    await expectLater(call(routesA, 'PUT', ['status'], body: {'created_by': b.deviceId, 'emoji': '👀'}), error(400));
    await call(routesA, 'DELETE', ['status']);
    expect((await routesA.statuses(fid)).single['text'], '');
    await call(routesA, 'PUT', ['status'], body: {'emoji': '🌱', 'text': '回来啦'});
    await a.patch(fid, '/families/$fid/members', a.deviceId, {'display_name': '甲新名', 'avatar_url': '/local/new?v=2'});
    final status = (await routesA.statuses(fid)).single;
    expect(status['sender_name'], '甲新名'); expect(status['sender_avatar_url'], '/local/new?v=2');
    final raw = (await a.list(fid, '/families/$fid/plugins/chat/status')).single;
    expect(raw.containsKey('sender_avatar_url'), false);
  });
  test('离开或撤销的成员不泄露旧头像快照且拒绝本机越权读取', () async {
    await send(routesA, 'former', '历史'); await transfer(a, b);
    await b.patch(fid, '/families/$fid/members', a.deviceId, {'status': 'revoked'});
    final former = (await routesB.snapshot(fid)).single;
    expect(former['sender_id'], isNull); expect(former['sender_avatar_url'], isNull); expect(former['sender_name'], '已离开的家人');
    await b.patch(fid, '/families/$fid/members', b.deviceId, {'status': 'revoked'});
    await expectLater(routesB.snapshot(fid), error(403));
  });
  test('未知字段和附件明确拒绝，原件路径不会借聊天进入日志', () async {
    await expectLater(call(routesA, 'POST', ['messages'], body: {'client_id': 'bad', 'body': 'x', 'file_path': '/private/original'}), error(400));
    await expectLater(call(routesA, 'POST', ['messages', 'image']), error(501));
    await expectLater(call(routesA, 'GET', ['messages', 'id', 'image', 'raw']), error(501));
    await expectLater(send(routesA, 'invalid\nclient', '正文'), error(400));
    await expectLater(send(routesA, 'empty', '  '), error(400));
    await expectLater(send(routesA, 'too-long', '字' * 2001), error(400));
    expect((await routesA.snapshot(fid)), isEmpty);
    final ops = LocalStore.canonical(await a.exportSince(fid, {}));
    expect(ops, isNot(contains('/private/original')));
  });
  test('非法历史游标不会返回跨家庭结果，消息不可编辑', () async {
    final sent = await send(routesA, 'immutable', '不可编辑');
    await expectLater(call(routesA, 'GET', ['messages'], query: {'after_id': sent['id']}), error(400));
    await expectLater(call(routesA, 'GET', ['messages'], query: {'limit': 201}), error(400));
    await expectLater(call(routesA, 'PATCH', ['messages', sent['id'] as String], body: {'body': '改写'}), error(405));
    await expectLater(routesA.request('GET', 'not-my-family', ['chat', 'messages']), error(403));
    expect((await routesA.snapshot(fid)).single['body'], '不可编辑');
  });
  test('持久草稿先落盘，重启显示显式失败可重试且私有字段不进日志', () async {
    final staged = await routesA.stageText(fid, clientId: 'durable', body: '未提交原文');
    expect((await routesA.snapshot(fid)), isEmpty);
    final pending = (await routesA.localSnapshot(fid)).single;
    expect(pending['id'], staged['id']); expect(pending['delivery_status'], 'failed_local');
    expect(LocalStore.canonical(await a.exportSince(fid, {})), isNot(contains('未提交原文')));
    await a.close(); a = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/a.sqlite');
    routesA = ChatRoutes(a, now: () => clock);
    expect((await routesA.localSnapshot(fid)).single['client_id'], 'durable');
    clock = DateTime.utc(2027, 1, 1);
    final first = routesA.commitPending(fid, 'durable'), duplicate = routesA.commitPending(fid, 'durable');
    expect(identical(first, duplicate), true);
    final saved = await first; await duplicate;
    expect(saved['id'], staged['id']); expect(saved['created_at'], staged['created_at']);
    expect((await routesA.localSnapshot(fid)).single['local_pending'], false);
    expect((await a.db.query('meta', where: 'key=?', whereArgs: ['private:chat-outbox:$fid:${a.deviceId}'])), isEmpty);
  });
  test('提交结果未知先查稳定回执再重试，不复制消息或复活撤回消息', () async {
    final staged = await routesA.stageText(fid, clientId: 'unknown-result', body: '只提交一次');
    // 模拟上次已提交、调用者尚未收到结果，并遗留私有草稿索引。
    await send(routesA, 'unknown-result', '只提交一次');
    await a.setPrivate('chat-outbox:$fid:${a.deviceId}', [{'client_id': 'unknown-result', 'body': '只提交一次', 'created_at': staged['created_at']}]);
    await a.close(); a = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/a.sqlite');
    routesA = ChatRoutes(a, now: () => clock);
    final receipt = await routesA.commitPending(fid, 'unknown-result');
    expect(receipt['id'], staged['id']); expect((await routesA.localSnapshot(fid)).length, 1);
    final writes = (await a.exportSince(fid, {})).where((op) => (op['collection'] as String).endsWith('/chat/messages'));
    expect(writes.length, 1);
    await call(routesA, 'DELETE', ['messages', staged['id'] as String]);
    final withdrawn = await routesA.commitPending(fid, 'unknown-result');
    expect(withdrawn['retracted'], true); expect(withdrawn['body'], isNull);
  });
  test('待发送草稿按家庭设备隔离，撤权不可读，丢弃不当成消息撤回', () async {
    await routesA.stageText(fid, clientId: 'private-draft', body: '甲的待发送内容');
    expect((await routesB.localSnapshot(fid)), isEmpty);
    await expectLater(routesA.localSnapshot('different-family'), error(403));
    await expectLater(routesA.stageText(fid, clientId: 'private-draft', body: '不一样'), error(409));
    await a.patch(fid, '/families/$fid/members', a.deviceId, {'status': 'revoked'});
    await expectLater(routesA.localSnapshot(fid), error(403));
    await expectLater(routesA.commitPending(fid, 'private-draft'), error(403));
    await a.patch(fid, '/families/$fid/members', a.deviceId, {'status': 'active'});
    await routesA.discardPending(fid, 'private-draft');
    expect((await routesA.localSnapshot(fid)), isEmpty);
    await expectLater(routesA.request('POST', fid, ['chat', 'messages'], body: {'client_id': 'private-draft', 'body': '甲的待发送内容'}, requirePending: true), error(409));
    expect((await a.exportSince(fid, {})).where((op) => (op['collection'] as String).endsWith('/chat/messages')), isEmpty);
  });

  test('消息提交事务失败同时回滚草稿确认，重试仍保留原client_id', () async {
    await routesA.stageText(fid, clientId: 'rollback', body: '保留直到事务提交');
    await a.db.execute("CREATE TRIGGER fail_chat_op BEFORE INSERT ON operations WHEN instr(NEW.payload, '/plugins/chat/messages') > 0 BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END");
    await expectLater(routesA.commitPending(fid, 'rollback'), throwsA(isA<DatabaseException>()));
    expect((await routesA.snapshot(fid)), isEmpty);
    final pending = (await routesA.localSnapshot(fid)).single;
    expect(pending['client_id'], 'rollback'); expect(pending['delivery_status'], 'failed_local');
    await a.db.execute('DROP TRIGGER fail_chat_op');
    final saved = await routesA.commitPending(fid, 'rollback');
    expect(saved['client_id'], 'rollback'); expect((await routesA.localSnapshot(fid)).length, 1);
    expect((await routesA.localSnapshot(fid)).single['local_pending'], false);
  });

}
