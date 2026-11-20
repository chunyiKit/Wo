import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/local/local_backend.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/recipe_expiry.dart';

void main() {
  sqfliteFfiInit();
  const fid = 'family-recipe';
  const recipes = '/families/$fid/plugins/recipe/recipes';
  const tags = '/families/$fid/plugins/recipe/tags';
  const items = '/families/$fid/plugins/expiry/items';
  late Directory directory;
  late LocalStore store;
  late RecipeExpiryRoutes routes;
  late DateTime clock;

  Future<void> seedMember(String family) => store.patch(
    family, '/families/$family/members', store.deviceId, {
      'user_id': store.deviceId, 'family_id': family, 'role': 'owner',
      'display_name': '本机成员', 'avatar_emoji': '🐱',
      'avatar_url': '/local/members/avatar?v=1', 'status': 'active',
      'joined_at': '2026-11-20T00:00:00Z',
    },
  ).then((_) {});

  Future<LocalResult> call(String method, List<String> tail, {
    Map<String, dynamic> body = const {},
    Map<String, dynamic> query = const {},
    String family = fid,
  }) async {
    final result = await routes.request(method, family, tail,
        body: body, query: query);
    expect(result, isNotNull, reason: '已知路由不能退回其它后端');
    return result!;
  }

  Future<Map<String, dynamic>> row(String method, List<String> tail, {
    Map<String, dynamic> body = const {},
    String family = fid,
  }) async => Map<String, dynamic>.from(
      (await call(method, tail, body: body, family: family)).data as Map);

  Matcher apiError(int status) => throwsA(isA<ApiException>()
      .having((error) => error.statusCode, 'statusCode', status));

  Future<void> reopen() async {
    await store.close();
    store = await LocalStore.open(factory: databaseFactoryFfi,
        path: '${directory.path}/local.sqlite');
    routes = RecipeExpiryRoutes(store, now: () => clock);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wo-recipe-expiry-');
    store = await LocalStore.open(factory: databaseFactoryFfi,
        path: '${directory.path}/local.sqlite');
    clock = DateTime(2026, 11, 20, 23, 59);
    routes = RecipeExpiryRoutes(store, now: () => clock);
    await seedMember(fid);
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('菜谱食材和步骤读写、局部修改与重启后模型解码', () async {
    final created = await row('POST', ['recipe', 'recipes'], body: {
      'name': ' 番茄炒蛋 ', 'emoji': '🍅', 'category': '午餐',
      'minutes': 15, 'difficulty': 2, 'servings': 2, 'note': '先炒蛋',
      'ingredients': [
        {'name': '番茄', 'amount': '2个'}, {'name': '鸡蛋', 'amount': '3个'},
      ],
      'steps': ['切番茄', '炒蛋', '合炒'],
    });
    final recipe = Recipe.fromJson(created);
    expect(recipe.name, '番茄炒蛋');
    expect(recipe.createdBy, store.deviceId);
    expect(recipe.familyId, fid);
    expect(recipe.creatorName, '本机成员');
    expect(recipe.creatorEmoji, '🐱');
    expect(recipe.creatorAvatarUrl, '/local/members/avatar?v=1');
    expect(recipe.ingredients.map((e) => e.toJson()), [
      {'name': '番茄', 'amount': '2个'}, {'name': '鸡蛋', 'amount': '3个'},
    ]);
    expect(recipe.steps, ['切番茄', '炒蛋', '合炒']);
    expect(recipe.hasCover, isFalse);
    final updated = await row('PUT', ['recipe', 'recipes', recipe.id], body: {
      'minutes': 20, 'servings': null, 'note': null,
      'ingredients': [{'name': '番茄', 'amount': '3个'}],
      'steps': ['重写步骤'],
    });
    expect(updated['name'], recipe.name);
    expect(updated['created_at'], created['created_at']);
    expect(updated['servings'], isNull);
    expect(updated['note'], isNull);
    await reopen();
    final read = Recipe.fromJson(await row('GET', ['recipe', 'recipes', recipe.id]));
    expect(read.minutes, 20);
    expect(read.ingredients.single.amount, '3个');
    expect(read.steps, ['重写步骤']);
    expect(read.createdAt, recipe.createdAt);
  });

  test('菜谱列表按创建时间排序并按分类筛选，删除留下持久墓碑', () async {
    final first = await row('POST', ['recipe', 'recipes'], body: {'name': '汤', 'category': '汤羹'});
    clock = clock.add(const Duration(minutes: 1));
    final second = await row('POST', ['recipe', 'recipes'], body: {'name': '饭', 'category': '午餐'});
    final all = (await call('GET', ['recipe', 'recipes'])).data as List;
    expect(all.map((e) => (e as Map)['id']), [second['id'], first['id']]);
    final filtered = (await call('GET', ['recipe', 'recipes'], query: {'category': '汤羹'})).data as List;
    expect(Recipe.fromJson(Map<String, dynamic>.from(filtered.single as Map)).name, '汤');
    expect((await call('DELETE', ['recipe', 'recipes', first['id'] as String])).data, isNull);
    await reopen();
    await expectLater(call('GET', ['recipe', 'recipes', first['id'] as String]), apiError(404));
    expect(await store.get(fid, recipes, first['id'] as String), isNull);
    final log = await store.exportSince(fid, {});
    expect(log.any((op) => op['id'] == first['id'] && op['kind'] == 'delete'), isTrue);
  });

  test('作者真实头像跟随本地成员更新，禁止伪造作者和跨家庭访问', () async {
    final created = await row('POST', ['recipe', 'recipes'], body: {'name': '面'});
    await store.patch(fid, '/families/$fid/members', store.deviceId, {
      'display_name': '改名', 'avatar_url': '/local/members/avatar?v=2',
    });
    final changed = Recipe.fromJson(await row('GET', ['recipe', 'recipes', created['id'] as String]));
    expect(changed.creatorName, '改名');
    expect(changed.creatorAvatarUrl, '/local/members/avatar?v=2');
    for (final forbidden in ['created_by', 'family_id', 'creator_avatar_url', 'id']) {
      await expectLater(call('POST', ['recipe', 'recipes'], body: {
        'name': '伪造', forbidden: 'attacker',
      }), apiError(400));
    }
    await expectLater(call('GET', ['recipe', 'recipes'], family: 'other-family'), apiError(403));
    await seedMember('other-family');
    await expectLater(call('GET', ['recipe', 'recipes', created['id'] as String], family: 'other-family'), apiError(404));
    await store.patch(fid, '/families/$fid/members', store.deviceId, {'status': 'revoked'});
    await expectLater(call('POST', ['recipe', 'recipes'], body: {'name': '无权'}), apiError(403));
    expect(await store.list(fid, recipes), hasLength(1));
  });

  test('菜谱输入校验失败不会留下记录；null 不能替代非空字段默认值', () async {
    final bad = <Map<String, dynamic>>[
      {'name': ' '}, {'name': 'x' * 65}, {'name': '菜', 'minutes': 1441},
      {'name': '菜', 'minutes': 1.5}, {'name': '菜', 'difficulty': 0},
      {'name': '菜', 'servings': 0}, {'name': '菜', 'emoji': null},
      {'name': '菜', 'steps': null}, {'name': '菜', 'steps': [7]},
      {'name': '菜', 'ingredients': [{'name': '盐', 'amount': null}]},
      {'name': '菜', 'ingredients': [{'name': '', 'amount': '一勺'}]},
      {'name': '菜', 'ingredients': [{'name': '盐', 'secret': 'x'}]},
    ];
    for (final body in bad) {
      await expectLater(call('POST', ['recipe', 'recipes'], body: body), apiError(400));
    }
    expect(await store.list(fid, recipes), isEmpty);
    final created = await row('POST', ['recipe', 'recipes'], body: {'name': '合法'});
    final before = await store.vector(fid);
    await expectLater(call('PUT', ['recipe', 'recipes', created['id'] as String], body: {'name': '改名', 'minutes': -1}), apiError(400));
    expect(await store.vector(fid), before);
    expect((await store.get(fid, recipes, created['id'] as String))!['name'], '合法');
  });

  test('默认标签一次初始化；删空和重启保持空，重新添加使用新 ID', () async {
    final names = (await call('GET', ['recipe', 'tags'])).data as List;
    expect(names, ['早餐', '午餐', '晚餐', '汤羹', '烘焙', '小食']);
    final original = await store.list(fid, tags);
    final ids = original.map((row) => row['id']).toSet();
    expect(ids.every((id) => RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id as String)), isTrue);
    for (final name in names) {
      await call('DELETE', ['recipe', 'tags'], query: {'name': name});
    }
    await reopen();
    expect((await call('GET', ['recipe', 'tags'])).data, isEmpty);
    expect((await call('POST', ['recipe', 'tags'], body: {'name': ' 早餐 '})).data, ['早餐']);
    expect((await call('POST', ['recipe', 'tags'], body: {'name': '早餐'})).data, ['早餐']);
    final added = (await store.list(fid, tags)).single;
    expect(ids, isNot(contains(added['id'])));
    expect((await store.list(fid, tags)), hasLength(1));
  });

  test('首次直接编辑标签不会补默认值，删标签不改既有菜谱分类', () async {
    final created = await row('POST', ['recipe', 'recipes'], body: {'name': '菜', 'category': '自选'});
    expect((await call('POST', ['recipe', 'tags'], body: {'name': '自选'})).data, ['自选']);
    await call('DELETE', ['recipe', 'tags'], query: {'name': '自选'});
    expect((await call('GET', ['recipe', 'tags'])).data, isEmpty);
    expect((await row('GET', ['recipe', 'recipes', created['id'] as String]))['category'], '自选');
    await seedMember('delete-first');
    expect((await call('DELETE', ['recipe', 'tags'], family: 'delete-first', query: {'name': '早餐'})).data, isEmpty);
    expect((await call('GET', ['recipe', 'tags'], family: 'delete-first')).data, isEmpty);
    await expectLater(call('POST', ['recipe', 'tags'], body: {'name': ' '}), apiError(400));
    await expectLater(call('POST', ['recipe', 'tags'], body: {'name': '长' * 17}), apiError(400));
    expect((await call('GET', ['recipe', 'tags'])).data, isEmpty);
  });

  test('同库两个 handler 并发初始化和加标签不产生重复', () async {
    final other = RecipeExpiryRoutes(store, now: () => clock);
    await Future.wait([
      call('GET', ['recipe', 'tags']),
      other.request('GET', fid, ['recipe', 'tags']),
    ]);
    await Future.wait([
      call('POST', ['recipe', 'tags'], body: {'name': '测试'}),
      other.request('POST', fid, ['recipe', 'tags'], body: {'name': '测试'}),
    ]);
    expect(await store.list(fid, tags), hasLength(7));
    expect((await call('GET', ['recipe', 'tags'])).data, [
      '早餐', '午餐', '晚餐', '汤羹', '烘焙', '小食', '测试',
    ]);
  });

  test('到期记录模型、提醒开关、日期更新及日历天数重算', () async {
    final created = await row('POST', ['expiry', 'items'], body: {
      'name': ' 护照 ', 'emoji': '🛂', 'kind': 'passport',
      'expire_on': '2026-11-21', 'note': '提前办理',
      'notify_enabled': true, 'notify_days_before': 90,
    });
    final item = ExpiryItem.fromJson(created);
    expect(item.name, '护照');
    expect(item.daysUntil, 1);
    expect(item.createdBy, store.deviceId);
    expect(item.notifyDaysBefore, 90);
    expect(item.active, isTrue);
    final updated = await row('PUT', ['expiry', 'items', item.id], body: {
      'expire_on': '2026-11-19', 'notify_enabled': false,
      'notify_days_before': 0, 'active': false, 'note': null,
    });
    expect(updated['created_at'], created['created_at']);
    final changed = ExpiryItem.fromJson(updated);
    expect(changed.daysUntil, -1);
    expect(changed.notifyEnabled, isFalse);
    expect(changed.active, isFalse);
    expect(changed.note, isNull);
    clock = DateTime(2026, 11, 22, 0, 1);
    await reopen();
    final list = (await call('GET', ['expiry', 'items'])).data as List;
    final read = ExpiryItem.fromJson(Map<String, dynamic>.from(list.single as Map));
    expect(read.daysUntil, -3);
    expect(read.expireOn, DateTime(2026, 11, 19));
    expect((await store.get(fid, items, item.id))!['expire_on'], '2026-11-19');
  });

  test('到期列表先启用后按日期排序，bool 筛选与永久删除', () async {
    final later = await row('POST', ['expiry', 'items'], body: {'name': '后', 'expire_on': '2027-01-01'});
    final early = await row('POST', ['expiry', 'items'], body: {'name': '先', 'expire_on': '2026-12-01'});
    final inactive = await row('POST', ['expiry', 'items'], body: {'name': '停用', 'expire_on': '2000-01-01', 'active': false});
    final all = (await call('GET', ['expiry', 'items'])).data as List;
    expect(all.map((e) => (e as Map)['id']), [early['id'], later['id'], inactive['id']]);
    for (final value in [false, 'false', 'FALSE']) {
      final filtered = (await call('GET', ['expiry', 'items'], query: {'active': value})).data as List;
      expect(filtered.single['id'], inactive['id']);
    }
    await expectLater(call('GET', ['expiry', 'items'], query: {'active': 'yes'}), apiError(400));
    expect((await call('DELETE', ['expiry', 'items', early['id'] as String])).data, isNull);
    await reopen();
    await expectLater(call('PUT', ['expiry', 'items', early['id'] as String], body: {'active': true}), apiError(404));
    expect(await store.list(fid, items), hasLength(2));
  });

  test('到期拒绝无效日历日、类型、范围和身份字段；接受闰年及最长 kind', () async {
    final base = <String, dynamic>{'name': '证件', 'expire_on': '2026-12-01'};
    for (final extra in <Map<String, dynamic>>[
      {'expire_on': '2026-02-30'}, {'expire_on': '2025-02-29'},
      {'expire_on': '2026-1-01'}, {'expire_on': '0000-01-01'},
      {'expire_on': '2026-12-01T00:00:00Z'}, {'kind': 'unknown'},
      {'kind': null}, {'notify_days_before': 366}, {'active': 1},
      {'notify_enabled': null}, {'name': ' '}, {'name': '字' * 41},
      {'created_by': 'forged'}, {'last_pre_notified_on': '2026-01-01'},
    ]) {
      await expectLater(call('POST', ['expiry', 'items'], body: {...base, ...extra}), apiError(400));
    }
    expect(await store.list(fid, items), isEmpty);
    final accepted = ExpiryItem.fromJson(await row('POST', ['expiry', 'items'], body: {
      ...base, 'kind': 'vehicle_inspection', 'expire_on': '2028-02-29',
    }));
    expect(accepted.kind, 'vehicle_inspection');
    expect(accepted.expireOn, DateTime(2028, 2, 29));
  });

  test('未匹配返回 null；错误方法和未接媒体明确报错，不假成功', () async {
    expect(await routes.request('GET', fid, ['recipe', 'unknown']), isNull);
    expect(await routes.request('GET', fid, ['expiry', 'items', 'one', 'extra']), isNull);
    await expectLater(call('DELETE', ['recipe', 'recipes']), apiError(405));
    await expectLater(call('PATCH', ['recipe', 'tags']), apiError(405));
    final recipe = await row('POST', ['recipe', 'recipes'], body: {'name': '菜'});
    for (final method in ['GET', 'POST', 'DELETE']) {
      await expectLater(call(method, ['recipe', 'recipes', recipe['id'] as String, 'cover']), apiError(501));
    }
    await expectLater(call('PATCH', ['recipe', 'recipes', recipe['id'] as String, 'cover']), apiError(405));
    expect((await store.get(fid, recipes, recipe['id'] as String))!['cover_version'], 0);
    final expiry = await row('POST', ['expiry', 'items'], body: {'name': '证件', 'expire_on': '2026-12-01'});
    await expectLater(call('GET', ['expiry', 'items', expiry['id'] as String]), apiError(405));
  });

  test('无 HTTP 客户端也可完成两个插件事实写读', () async {
    await HttpOverrides.runZoned(() async {
      await row('POST', ['recipe', 'recipes'], body: {'name': '离线菜谱'});
      await row('POST', ['expiry', 'items'], body: {'name': '离线到期', 'expire_on': '2027-01-01'});
      expect((await call('GET', ['recipe', 'recipes'])).data, hasLength(1));
      expect((await call('GET', ['expiry', 'items'])).data, hasLength(1));
    }, createHttpClient: (_) => throw StateError('此模块不允许创建 HTTP 客户端'));
  });
}
