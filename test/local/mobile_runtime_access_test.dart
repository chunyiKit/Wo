// 已准备的本地API集成回归；当前未执行Dart/Flutter/SDK。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/local/local_api.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/local_media_repository.dart';
import 'package:wo/local/media/native_media.dart';
import 'package:wo/local/plugins/memory_routes.dart';
import 'package:wo/local/plugins/chat_routes.dart';
import 'package:wo/local/sync/peer_registry.dart';

void main() {
  sqfliteFfiInit();
  const fid = 'shared-family';
  late Directory directory;
  late LocalStore a, b;
  late LocalApi apiA, apiB;
  late MemoryRoutes memoriesA, memoriesB;
  Matcher error(int code) => throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', code));
  Future<void> transfer(LocalStore from, LocalStore to) async {
    for (var round = 0; round < 100; round++) {
      final ops = await from.exportSince(fid, await to.vector(fid));
      if (ops.isEmpty) return;
      await to.merge(fid, ops);
    }
    fail('合成增量没有结束');
  }
  Future<Json> bootstrap(LocalApi api) async => Json.from((await api.request('GET', '/me/bootstrap')).data as Map);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wo-runtime-access-');
    a = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/a.sqlite');
    b = await LocalStore.open(factory: databaseFactoryFfi, path: '${directory.path}/b.sqlite');
    for (final destination in [a, b]) {
      await destination.patch(fid, '/families/$fid/family', fid, {'name': '授权家庭标题', 'emoji': '🏠', 'created_at': '2026-11-20T00:00:00Z'});
      for (final member in [a, b]) {
        await destination.patch(fid, '/families/$fid/members', member.deviceId, {
          'family_id': fid, 'user_id': member.deviceId, 'status': 'active', 'role': member == a ? 'owner' : 'member',
          'display_name': member == a ? '甲' : '乙', 'avatar_emoji': '👤', 'avatar_url': null,
          'joined_at': '2026-11-20T00:00:00Z',
        });
      }
      await destination.setPrivate('families', [fid]); await destination.setPrivate('current-family', fid);
    }
    memoriesA = MemoryRoutes(a, media: LocalMediaRepository(a, native: NativeMedia(), directory: Directory('${directory.path}/thumb-a')), access: LocalMemoryAccess(a));
    memoriesB = MemoryRoutes(b, media: LocalMediaRepository(b, native: NativeMedia(), directory: Directory('${directory.path}/thumb-b')), access: LocalMemoryAccess(b));
    apiA = LocalApi(a, memories: memoriesA); apiB = LocalApi(b, memories: memoriesB);
    await apiA.initialize(); await apiB.initialize();
  });
  tearDown(() async { await a.close(); await b.close(); await directory.delete(recursive: true); });

  test('同家庭两个成员的首页预览按各自权限重算，不广播私密计数或标题', () async {
    await apiA.request('POST', '/families/$fid/plugins', body: {'plugin_id': 'memory'});
    await memoriesA.request('POST', fid, ['memory', 'memories'], body: {'title': '仅甲可见的私密正文标题', 'visibility': 'private', 'event_date': '2026-11-20'});
    await memoriesA.request('POST', fid, ['memory', 'memories'], body: {'title': '全家可见回忆', 'visibility': 'family', 'event_date': '2026-11-20'});
    expect(LocalStore.canonical(await a.exportSince(fid, {})), isNot(contains('仅甲可见的私密正文标题')));
    await transfer(a, b);
    final bootA = await bootstrap(apiA), bootB = await bootstrap(apiB);
    final cardA = (bootA['installed_plugins'] as List).single as Map, cardB = (bootB['installed_plugins'] as List).single as Map;
    expect((cardA['preview'] as Map)['primary'], '2 段可见回忆');
    expect((cardB['preview'] as Map)['primary'], '1 段可见回忆');
    expect(jsonEncode(bootB), isNot(contains('仅甲可见的私密正文标题')));
    final installed = (await b.list(fid, '/families/$fid/installed')).single;
    expect(installed.containsKey('preview'), false);
  });

  test('撤权后bootstrap不显示旧家庭卡片且不新建覆盖，另一成员不受影响', () async {
    await apiA.request('POST', '/families/$fid/plugins', body: {'plugin_id': 'recipe'});
    await apiA.request('POST', '/families/$fid/plugins/recipe/recipes', body: {'name': '旧家庭隐藏菜谱'});
    await transfer(a, b);
    expect((await bootstrap(apiB))['current_family'], isNotNull);
    await a.patch(fid, '/families/$fid/members', b.deviceId, {'status': 'revoked'});
    await transfer(a, b);
    final bootB = await bootstrap(apiB);
    expect(bootB['current_family'], isNull); expect(bootB['families'], isEmpty); expect(bootB['installed_plugins'], isEmpty);
    for (final hidden in ['授权家庭标题', '旧家庭隐藏菜谱']) { expect(jsonEncode(bootB), isNot(contains(hidden))); }
    expect(await b.privateValue('families'), [fid]); expect(await b.privateValue('current-family'), isNull);
    expect(await b.list(fid, '/families/$fid/installed'), hasLength(1));
    await apiB.initialize(); expect((await bootstrap(apiB))['families'], isEmpty);
    expect(await b.privateValue('families'), [fid]);
    await expectLater(apiB.request('GET', '/families/$fid/plugins'), error(403));
    final meB = Json.from((await apiB.request('GET', '/me')).data as Map);
    expect(meB['current_family'], isNull); expect((meB['stats'] as Map)['families_joined'], 0);
    expect((await apiB.request('GET', '/me/families')).data, isEmpty);
    final bootA = await bootstrap(apiA);
    expect((bootA['current_family'] as Map)['id'], fid); expect(bootA['installed_plugins'], hasLength(1));
  });

  test('当前家庭撤权选择已有有效家庭，旧私有outbox留盘但不可跨家庭展示', () async {
    await ChatRoutes(b).stageText(fid, clientId: 'family-private-outbox', body: '旧家庭未发送原文');
    final second = Json.from((await apiB.request('POST', '/families', body: {'name': '有效备用家庭'})).data as Map);
    await apiB.request('POST', '/families/$fid/switch');
    await a.patch(fid, '/families/$fid/members', b.deviceId, {'status': 'revoked'}); await transfer(a, b);
    final boot = await bootstrap(apiB);
    expect((boot['current_family'] as Map)['id'], second['id']);
    expect((boot['families'] as List).map((row) => (row as Map)['id']), [second['id']]);
    expect(jsonEncode(boot), isNot(contains('旧家庭未发送原文')));
    await expectLater(ChatRoutes(b).localSnapshot(fid), error(403));
    expect(await ChatRoutes(b).localSnapshot(second['id'] as String), isEmpty);
    expect(await b.privateValue('chat-outbox:$fid:${b.deviceId}'), isNotNull);
    expect((await b.privateValue('families') as List).toSet(), {fid, second['id']});
  });

  test('status为active但身份、家庭或role不匹配的成员仍被API排除', () async {
    for (final bad in [{'user_id': a.deviceId}, {'family_id': 'other-family'}, {'role': 'unexpected'}]) {
      await b.patch(fid, '/families/$fid/members', b.deviceId, bad);
      final boot = await bootstrap(apiB);
      expect(boot['current_family'], isNull); expect(boot['families'], isEmpty);
      await expectLater(apiB.request('GET', '/families/$fid'), error(403));
      await b.patch(fid, '/families/$fid/members', b.deviceId, {'family_id': fid, 'user_id': b.deviceId, 'role': 'member', 'status': 'active'});
      expect((await bootstrap(apiB))['current_family'], isNotNull);
    }
  });
  test('家庭未读计数从当前设备的本地通知与已读状态派生',()async{
    final api=apiA,target=apiA.familyId!;
    await a.patch(target,'/families/$target/notifications','synthetic-notification',{'type':'synthetic','title':'合成提醒','body':'合成正文','icon_emoji':'🔔','created_by':a.deviceId,'created_at':'2026-11-20T00:00:00Z','read_by':<String>[],'status':'pending_local_delivery','recipient_ids':[a.deviceId],'source_plugin':'chore','source_id':'synthetic'});
    final first=await bootstrap(api);
    expect((first['current_family'] as Map)['my_unread_count'],1);expect(first['unread_count'],1);
    await transfer(a,b);
    expect((await bootstrap(apiB))['unread_count'],0);
    await api.request('PATCH','/notifications/synthetic-notification/read');
    final second=await bootstrap(api);
    expect((second['current_family'] as Map)['my_unread_count'],0);expect(second['unread_count'],0);
  });

}
