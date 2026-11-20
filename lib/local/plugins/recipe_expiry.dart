import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../local_backend.dart';
import '../local_notification_preferences.dart';
import '../local_store.dart';

/// 菜谱与到期记录的本地业务契约。封面媒体尚未接入，绝不退回云端写入。
class RecipeExpiryRoutes {
  RecipeExpiryRoutes(this.store, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final LocalStore store;
  final DateTime Function() _now;
  static const _uuid = Uuid();
  static const _tagNamespace = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';
  static const _defaultTags = ['早餐', '午餐', '晚餐', '汤羹', '烘焙', '小食'];
  static const _recipeFields = {
    'name', 'emoji', 'category', 'minutes', 'difficulty', 'servings', 'note',
    'ingredients', 'steps',
  };
  static const _expiryFields = {
    'name', 'emoji', 'kind', 'expire_on', 'note', 'notify_enabled',
    'notify_days_before', 'active',
  };
  static const _kinds = {
    'id_card', 'passport', 'visa', 'driver_license', 'vehicle_inspection',
    'insurance', 'contract', 'membership', 'household', 'other',
  };
  static final _ids = RegExp(r'^[a-zA-Z0-9_-]{1,100}$');
  static final _tagQueues = Expando<Map<String, Future<void>>>();

  Future<LocalResult?> request(
    String method,
    String fid,
    List<String> tail, {
    Map<String, dynamic> body = const {},
    Map<String, dynamic> query = const {},
  }) async {
    if (tail.length < 2) return null;
    final recipe = tail[0] == 'recipe' && tail[1] == 'recipes' &&
        (tail.length == 2 || tail.length == 3 ||
            (tail.length == 4 && tail[3] == 'cover'));
    final tags = tail[0] == 'recipe' && tail[1] == 'tags' && tail.length == 2;
    final expiry = tail[0] == 'expiry' && tail[1] == 'items' &&
        (tail.length == 2 || tail.length == 3);
    if (!recipe && !tags && !expiry) return null;
    await _requireMember(fid);
    final verb = method.toUpperCase();
    if (tags) {
      return _serializeTags(fid, () => _tagsRequest(verb, fid, body, query));
    }
    if (recipe) {
      return _recipeRequest(verb, fid, tail, body, query);
    }
    return _expiryRequest(verb, fid, tail, body, query);
  }

  Future<void> _requireMember(String fid) async {
    if (!_ids.hasMatch(fid)) _invalid('家庭标识无效');
    final member = await store.get(fid, '/families/$fid/members', store.deviceId);
    if (member == null || member['status'] != 'active' ||
        member['family_id'] != fid || member['user_id'] != store.deviceId) {
      throw ApiException('FORBIDDEN', '当前本机身份不是此家庭的有效成员', statusCode: 403);
    }
  }

  Future<Map<String, dynamic>> _load(String fid, String col, String id) async {
    if (!_ids.hasMatch(id)) _invalid('记录标识无效');
    final row = await store.get(fid, col, id);
    if (row == null || row['family_id'] != fid) {
      throw ApiException('NOT_FOUND', '记录不存在', statusCode: 404);
    }
    return row;
  }

  static Never _invalid(String message) =>
      throw ApiException('VALIDATION_ERROR', message, statusCode: 400);
  static Never _method() =>
      throw ApiException('METHOD_NOT_ALLOWED', '此记录不支持该操作', statusCode: 405);
  static void _only(Map<String, dynamic> value, Set<String> allowed) {
    if (value.keys.any((key) => !allowed.contains(key))) _invalid('包含不支持或只读字段');
  }

  static String _text(Object? value, String label, int max,
      {bool empty = false}) {
    if (value is! String) _invalid('$label 必须是文本');
    final text = value.trim();
    if ((!empty && text.isEmpty) || text.runes.length > max) {
      _invalid('$label 为空或超过长度限制');
    }
    return text;
  }

  static String? _note(Object? value, int max) {
    if (value == null) return null;
    if (value is! String || value.runes.length > max) _invalid('备注无效或过长');
    return value;
  }

  // 缺省值只适用于未提供字段；显式 null 不能悄悄变成默认值。
  static Object? _value(Map<String, dynamic> body, String key, Object fallback) =>
      body.containsKey(key) ? body[key] : fallback;

  static int _integer(Object? value, String label, int min, int max) {
    if (value is! int || value < min || value > max) _invalid('$label 超出范围');
    return value;
  }

  static bool _boolean(Object? value, String label) {
    if (value is! bool) _invalid('$label 必须是开关值');
    return value;
  }

  static bool? _filterBool(Object? value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is String && ['true', 'false'].contains(value.toLowerCase())) {
      return value.toLowerCase() == 'true';
    }
    _invalid('筛选开关无效');
  }

  static String _date(Object? value) {
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      _invalid('日期必须是 YYYY-MM-DD');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null || parsed.year < 1 || parsed.year > 9999 ||
        '${parsed.year.toString().padLeft(4, '0')}-'
            '${parsed.month.toString().padLeft(2, '0')}-'
            '${parsed.day.toString().padLeft(2, '0')}' != value) {
      _invalid('日期不存在');
    }
    return value;
  }

  Future<void> _save(String fid, String col, String id,
      Map<String, dynamic> fields, {bool delete = false}) async {
    try {
      await store.patch(fid, col, id, fields, delete: delete);
    } on FormatException {
      _invalid('记录超过本地大小限制或包含无效内容');
    }
  }

  Map<String, dynamic> _recipeValues(Map<String, dynamic> body,
      {required bool create}) {
    _only(body, _recipeFields);
    final values = <String, dynamic>{};
    if (create || body.containsKey('name')) {
      values['name'] = _text(body['name'], '菜名', 64);
    }
    if (create || body.containsKey('emoji')) {
      values['emoji'] = _text(_value(body, 'emoji', '🍳'), '图标', 16);
    }
    if (create || body.containsKey('category')) {
      values['category'] = _text(_value(body, 'category', ''),
          '分类', 16, empty: true);
    }
    if (create || body.containsKey('minutes')) {
      values['minutes'] = _integer(_value(body, 'minutes', 0),
          '烹饪时间', 0, 1440);
    }
    if (create || body.containsKey('difficulty')) {
      values['difficulty'] = _integer(_value(body, 'difficulty', 1),
          '难度', 1, 3);
    }
    if (create || body.containsKey('servings')) {
      values['servings'] = body['servings'] == null ? null :
          _integer(body['servings'], '份数', 1, 99);
    }
    if (create || body.containsKey('note')) values['note'] = _note(body['note'], 500);
    if (create || body.containsKey('ingredients')) {
      final raw = _value(body, 'ingredients', <dynamic>[]);
      if (raw is! List) _invalid('食材必须是列表');
      values['ingredients'] = [
        for (final item in raw) _ingredient(item),
      ];
    }
    if (create || body.containsKey('steps')) {
      final raw = _value(body, 'steps', <dynamic>[]);
      if (raw is! List || raw.any((item) => item is! String)) _invalid('步骤必须是文本列表');
      values['steps'] = [for (final item in raw) item as String];
    }
    return values;
  }

  static Map<String, dynamic> _ingredient(Object? raw) {
    if (raw is! Map || raw.keys.any((key) => key != 'name' && key != 'amount')) {
      _invalid('食材结构无效');
    }
    return {
      'name': _text(raw['name'], '食材名称', 32),
      'amount': _text(_value(Map<String, dynamic>.from(raw), 'amount', ''), '食材用量', 32, empty: true),
    };
  }

  Future<Map<String, dynamic>> _recipeRead(String fid,
      Map<String, dynamic> row) async {
    final author = row['created_by'];
    final member = author is String && _ids.hasMatch(author)
        ? await store.get(fid, '/families/$fid/members', author) : null;
    final visible = member != null && member['status'] == 'active' &&
        member['family_id'] == fid && member['user_id'] == author;
    return {
      ...row,
      'creator_name': visible ? member?['display_name'] : null,
      'creator_emoji': visible ? member?['avatar_emoji'] : null,
      'creator_avatar_url': visible ? member?['avatar_url'] : null,
      'cover_version': row['cover_version'] ?? 0,
      'cover_url': row['cover_url'],
    };
  }

  Future<LocalResult> _recipeRequest(String verb, String fid, List<String> tail,
      Map<String, dynamic> body, Map<String, dynamic> query) async {
    final col = '/families/$fid/plugins/recipe/recipes';
    if (tail.length == 4) {
      if (!['GET', 'POST', 'DELETE'].contains(verb)) _method();
      await _load(fid, col, tail[2]);
      throw ApiException('FEATURE_UNAVAILABLE', '菜谱图片尚未接入本地媒体模块，请保留原文件', statusCode: 501);
    }
    if (tail.length == 2) {
      if (verb == 'GET') {
        _only(query, {'category'});
        final category = query['category'] == null ? null :
            _text(query['category'], '分类', 16, empty: true);
        final rows = (await store.list(fid, col)).where((row) =>
            category == null || category.isEmpty || row['category'] == category).toList();
        rows.sort((a, b) {
          final date = (b['created_at'] as String).compareTo(a['created_at'] as String);
          return date != 0 ? date : (a['id'] as String).compareTo(b['id'] as String);
        });
        return (data: [for (final row in rows) await _recipeRead(fid, row)], meta: null);
      }
      if (verb != 'POST') _method();
      final fields = _recipeValues(body, create: true);
      final id = _uuid.v4();
      await _save(fid, col, id, {
        ...fields, 'family_id': fid, 'created_by': store.deviceId,
        'created_at': _now().toUtc().toIso8601String(),
        'cover_version': 0, 'cover_url': null,
      });
      return (data: await _recipeRead(fid, await _load(fid, col, id)), meta: null);
    }
    final row = await _load(fid, col, tail[2]);
    if (verb == 'GET') return (data: await _recipeRead(fid, row), meta: null);
    if (verb == 'DELETE') {
      await _save(fid, col, tail[2], {}, delete: true);
      return (data: null, meta: null);
    }
    if (verb != 'PUT') _method();
    final fields = _recipeValues(body, create: false);
    if (fields.isNotEmpty) await _save(fid, col, tail[2], fields);
    return (data: await _recipeRead(fid, await _load(fid, col, tail[2])), meta: null);
  }

  Future<LocalResult> _serializeTags(String fid,
      Future<LocalResult> Function() action) {
    final queues = _tagQueues[store] ??= <String, Future<void>>{};
    final done = Completer<LocalResult>();
    queues[fid] = (queues[fid] ?? Future<void>.value()).then((_) async {
      try { done.complete(await action()); }
      catch (error, stack) { done.completeError(error, stack); }
    });
    return done.future;
  }

  Future<List<Map<String, dynamic>>> _tagRows(String fid) async {
    final rows = await store.list(fid, '/families/$fid/plugins/recipe/tags');
    rows.sort((a, b) {
      final order = (a['order'] as int).compareTo(b['order'] as int);
      return order != 0 ? order : (a['id'] as String).compareTo(b['id'] as String);
    });
    return rows;
  }

  Future<List<String>> _tagNames(String fid) async => [
    ...{for (final row in await _tagRows(fid)) row['name'] as String},
  ];

  Future<LocalResult> _tagsRequest(String verb, String fid,
      Map<String, dynamic> body, Map<String, dynamic> query) async {
    if (!['GET', 'POST', 'DELETE'].contains(verb)) _method();
    final col = '/families/$fid/plugins/recipe/tags';
    final settings = '/families/$fid/plugins/recipe/settings';
    final seeded = (await store.get(fid, settings, 'palette'))?['seeded'] == true;
    final rows = await _tagRows(fid);
    final changes = <Map<String, dynamic>>[];
    if (!seeded) {
      changes.add({'space': fid, 'collection': settings, 'id': 'palette',
        'fields': {'seeded': true}});
    }
    if (verb == 'GET') {
      _only(query, <String>{});
      if (!seeded && rows.isEmpty) {
        for (var index = 0; index < _defaultTags.length; index++) {
          final name = _defaultTags[index];
          changes.add({'space': fid, 'collection': col,
            'id': _uuid.v5(_tagNamespace, 'wo-recipe-default:$fid:$name'),
            'fields': {'name': name, 'order': index}});
        }
      }
    } else if (verb == 'POST') {
      _only(body, {'name'}); _only(query, <String>{});
      final name = _text(body['name'], '标签', 16);
      if (!rows.any((row) => row['name'] == name)) {
        changes.add({'space': fid, 'collection': col, 'id': _uuid.v4(),
          'fields': {'name': name, 'order': rows.isEmpty ? 0 : (rows.last['order'] as int) + 1}});
      }
    } else {
      _only(body, <String>{}); _only(query, {'name'});
      final name = _text(query['name'], '标签', 16);
      for (final row in rows.where((row) => row['name'] == name)) {
        changes.add({'space': fid, 'collection': col, 'id': row['id'],
          'fields': <String, dynamic>{}, 'delete': true});
      }
    }
    if (changes.isNotEmpty) await store.batch(changes);
    return (data: await _tagNames(fid), meta: null);
  }

  Map<String, dynamic> _expiryValues(Map<String, dynamic> body,
      {required bool create}) {
    _only(body, _expiryFields);
    final values = <String, dynamic>{};
    if (create || body.containsKey('name')) values['name'] = _text(body['name'], '名称', 40);
    if (create || body.containsKey('emoji')) {
      values['emoji'] = _text(_value(body, 'emoji', '📄'), '图标', 16);
    }
    if (create || body.containsKey('kind')) {
      final kind = _value(body, 'kind', 'other');
      if (kind is! String || !_kinds.contains(kind)) _invalid('到期类型无效');
      values['kind'] = kind;
    }
    if (create || body.containsKey('expire_on')) values['expire_on'] = _date(body['expire_on']);
    if (create || body.containsKey('note')) values['note'] = _note(body['note'], 200);
    if (create || body.containsKey('notify_enabled')) {
      values['notify_enabled'] = _boolean(_value(body, 'notify_enabled', true), '提醒');
    }
    if (create || body.containsKey('active')) {
      values['active'] = _boolean(_value(body, 'active', true), '启用');
    }
    if (create || body.containsKey('notify_days_before')) {
      values['notify_days_before'] = _integer(_value(body, 'notify_days_before', 30), '提前天数', 0, 365);
    }
    return values;
  }

  Map<String, dynamic> _expiryRead(Map<String, dynamic> row) {
    final date = DateTime.parse(row['expire_on'] as String);
    final now = _now();
    final delta = DateTime.utc(date.year, date.month, date.day)
        .difference(DateTime.utc(now.year, now.month, now.day)).inDays;
    return {...row, 'days_until': delta};
  }

  Future<LocalResult> _expiryRequest(String verb, String fid, List<String> tail,
      Map<String, dynamic> body, Map<String, dynamic> query) async {
    final col = '/families/$fid/plugins/expiry/items';
    if (tail.length == 2) {
      if (verb == 'GET') {
        _only(query, {'active'});
        final active = _filterBool(query['active']);
        final rows = (await store.list(fid, col)).where((row) =>
            active == null || row['active'] == active).toList();
        rows.sort((a, b) {
          final status = (b['active'] == true ? 1 : 0) - (a['active'] == true ? 1 : 0);
          if (status != 0) return status;
          final date = (a['expire_on'] as String).compareTo(b['expire_on'] as String);
          return date != 0 ? date : (a['id'] as String).compareTo(b['id'] as String);
        });
        return (data: [for (final row in rows) _expiryRead(row)], meta: null);
      }
      if (verb != 'POST') _method();
      final id = _uuid.v4();
      await _save(fid, col, id, {
        ..._expiryValues(body, create: true), 'family_id': fid,
        'created_by': store.deviceId, 'created_at': _now().toUtc().toIso8601String(),
      });
      return (data: _expiryRead(await _load(fid, col, id)), meta: null);
    }
    await _load(fid, col, tail[2]);
    if (verb == 'DELETE') {
      await _save(fid, col, tail[2], {}, delete: true);
      return (data: null, meta: null);
    }
    if (verb != 'PUT') _method();
    final fields = _expiryValues(body, create: false);
    if (fields.isNotEmpty) await _save(fid, col, tail[2], fields);
    return (data: _expiryRead(await _load(fid, col, tail[2])), meta: null);
  }
  /// 仅创建前台可读消息请求，不调用原生调度，也不自动续期。
  /// 与安装开关、成员状态及通知墓碑的读取在同一SQLite事务内完成。
  Future<int> requestDueExpiryReminders(String fid) async {
    await _requireMember(fid);
    final now = _now();
    final today = DateTime.utc(now.year, now.month, now.day);
    final stamp = now.toUtc().toIso8601String();
    final changes = await store.batchComputed((tx) async {
      Future<List<Json>> documents(String collection) async => [
        for (final row in await tx.query('documents', columns: ['id', 'data'],
          where: 'space=? AND collection=? AND deleted=0', whereArgs: [fid, collection]))
          {...Json.from(jsonDecode(row['data'] as String) as Map), 'id': row['id']},
      ];
      final members = await documents('/families/$fid/members');
      bool activeMember(Json member) => member['id'] is String &&
        _ids.hasMatch(member['id'] as String) && member['family_id'] == fid &&
        member['user_id'] == member['id'] && member['status'] == 'active';
      if (!members.any((m) => activeMember(m) && m['id'] == store.deviceId)) {
        throw ApiException('FORBIDDEN', '本机成员身份已失效，未生成到期消息', statusCode: 403);
      }
      final preferenceRows = await tx.query('meta', columns: ['value'],
        where: 'key=?', whereArgs: ['private:${LocalNotificationPreferences.privateKey}']);
      dynamic rawPreferences;
      if (preferenceRows.isNotEmpty) {
        try { rawPreferences = jsonDecode(preferenceRows.single['value'] as String); }
        catch (_) { return <Json>[]; } // 损坏配置不能回落为默认开启。
      }
      if (!LocalNotificationPreferences.fromPrivateValue(rawPreferences).expiryEnabled) return <Json>[];
      final installed = await documents('/families/$fid/installed');
      if (!installed.any((row) => row['plugin_id'] == 'expiry' && row['enabled'] == true)) return <Json>[];
      // 每设备只生成自己的本机消息；不让不同actor共用不可变作者的通知ID。
      final recipients = <String>[store.deviceId];
      final items = await documents('/families/$fid/plugins/expiry/items');
      items.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
      final requests = <Json>[];
      for (final row in items) {
        if (row['family_id'] != fid || row['active'] != true) continue;
        String due, name, emoji; int ahead; bool enabled;
        try {
          due = _date(row['expire_on']); name = _text(row['name'], '名称', 40);
          emoji = _text(row['emoji'], '图标', 16);
          ahead = _integer(row['notify_days_before'], '提前天数', 0, 365);
          enabled = _boolean(row['notify_enabled'], '到期前提醒');
        } on ApiException { continue; }
        final parsed = DateTime.parse(due);
        final delta = DateTime.utc(parsed.year, parsed.month, parsed.day).difference(today).inDays;
        // 基线开关仅指“到期前提醒”；active=false才暂停预提醒和过期提醒。
        final overdue = delta < 0;
        if (!overdue && (!enabled || delta > ahead)) continue;
        final type = overdue ? 'expiry_expired' : 'expiry_due';
        final id = _uuid.v5(_tagNamespace, 'expiry:$fid:${row['id']}:$due:$type:${store.deviceId}');
        final previous = await tx.query('documents', columns: ['id'],
          where: 'space=? AND collection=? AND id=?',
          whereArgs: [fid, '/families/$fid/notifications', id], limit: 1);
        // 读过、隐藏过或已删除的同轮次通知均不重建，不把墓碑ID复用。
        if (previous.isNotEmpty) continue;
        final when = delta == 0 ? '今天' : '$delta 天后';
        requests.add({'space': fid, 'collection': '/families/$fid/notifications', 'id': id,
          'fields': {'type': type, 'title': overdue ? '「$name」已过期' : '「$name」$when到期',
            'body': overdue ? '已过期 ${-delta} 天，记得尽快续期 📄' : '记得提前安排续期 📄',
            'icon_emoji': emoji, 'created_by': store.deviceId, 'created_at': stamp,
            'read_by': <String>[], 'status': 'pending_local_delivery', 'recipient_ids': recipients,
            'source_plugin': 'expiry', 'source_id': row['id'], 'source_occurrence': due}});
        // 每批保持LocalStore事务上限；余项在下一次前台检查继续，已生成项不再占名额。
        if (requests.length == 256) break;
      }
      return requests;
    });
    return changes.length;
  }

}
