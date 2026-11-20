import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../local_backend.dart';
import '../local_store.dart';
import '../backup/backup_models.dart' show decodeBackupJson;

/// 库存数量只派生自不可变事件；名称等元数据仍采用既有字段合并。
class StockAccountingRoutes {
  StockAccountingRoutes(this.store, {DateTime Function()? now})
      : now = now ?? DateTime.now;
  final LocalStore store;
  final DateTime Function() now;
  static const uuid = Uuid();
  static const namespace = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';
  static final ids = RegExp(r'^[a-zA-Z0-9_-]{1,100}$');
  static const maxQuantity = 1000000000;

  /// Operation-envelope fields only. JSON inside event/entry must also be
  /// decoded and checked against the exported embedded schemas below.
  static const syncFields = <String, Set<String>>{
    'plugins/stock/items': {'family_id', 'created_by', 'created_at', 'name', 'emoji', 'unit', 'low_at', 'note', 'creation_request'},
    'plugins/stock/buys': {'family_id', 'created_by', 'created_at', 'name', 'emoji', 'want_qty', 'note', 'stock_item_id', 'creation_request'},
    'plugins/stock/events': {'event'},
    'plugins/stock/requests': {'fingerprint', 'response'},
    'plugins/accounting/categories': {'family_id', 'label', 'emoji', 'created_at'},
    'plugins/accounting/transactions': {'family_id', 'entry'},
    'plugins/accounting/budget': {'family_id', 'entry'},
    'plugins/accounting/requests': {'fingerprint', 'response'},
  };
  static const immutableCollections = <String>{'plugins/stock/events'};
  static const eventFields = <String>{'event_id', 'type', 'item_id', 'buy_id', 'cycle', 'next_cycle', 'delta', 'ack', 'order', 'actor', 'created_at'};
  static const eventSemanticFields = <String>{'type', 'item_id', 'buy_id', 'cycle', 'next_cycle', 'delta', 'ack'};
  static const entryBaseFields = <String>{'family_id', 'created_by', 'created_at', 'calendar_date', 'calendar_offset_minutes', 'amount_minor', 'category', 'note', 'exclude_from_budget'};
  static const entrySourceFields = <String>{'source_plugin', 'source_id', 'source_occurrence', 'source_event_id'};
  static const entryFields = <String>{...entryBaseFields, ...entrySourceFields};
  static const budgetEntryFields = <String>{'monthly_amount_minor', 'updated_at', 'updated_by'};
  static const requestResponseFields = <String>{...entrySourceFields, 'id', 'family_id', 'created_by', 'created_at', 'name', 'emoji', 'qty', 'unit', 'low_at', 'note', 'creation_request', 'raw_qty', 'quantity_conflict', 'quantity_conflicts', 'is_low', 'creator_name', 'creator_emoji', 'creator_avatar_url', 'want_qty', 'stock_item_id', 'bought', 'bought_at', 'purchase_cycle', 'receipt_conflict', 'deleted', 'code', 'label', 'amount', 'amount_minor', 'category', 'exclude_from_budget', 'calendar_date', 'calendar_offset_minutes', 'monthly_amount'};

  static String eventSemantic(Json event) {
    final value = {for (final key in eventSemanticFields) if (event.containsKey(key)) key: event[key]};
    if (value['ack'] is List) value['ack'] = (value['ack'] as List).cast<String>().toSet().toList()..sort();
    return LocalStore.canonical(value);
  }

  static Json decodeEvent(Object? encoded, {String? expectedId, String? actor, int? order}) {
    Never bad() => throw const FormatException('库存事件结构或来源无效');
    if (encoded is! String) bad();
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) bad();
    final event = Json.from(decoded);
    if (event.keys.any((k) => !eventFields.contains(k)) ||
        event['event_id'] is! String || !ids.hasMatch(event['event_id'] as String) ||
        event['actor'] is! String || !ids.hasMatch(event['actor'] as String) ||
        event['order'] is! int || (event['order'] as int) < 1 ||
        expectedId != null && event['event_id'] != expectedId ||
        actor != null && event['actor'] != actor || order != null && event['order'] != order ||
        event['created_at'] is! String || DateTime.tryParse(event['created_at'] as String) == null) bad();
    final type = event['type'];
    bool id(Object? value) => value is String && ids.hasMatch(value);
    if (type == 'delta') {
      if (!id(event['item_id']) || event['delta'] is! int || (event['delta'] as int).abs() > safeMinor ||
          event['ack'] is! List || (event['ack'] as List).length > 4096 || (event['ack'] as List).any((v) => v is! String) ||
          event.keys.any((k) => !{'event_id', 'type', 'item_id', 'delta', 'ack', 'order', 'actor', 'created_at'}.contains(k))) bad();
    } else if (type == 'receipt') {
      if (!id(event['buy_id']) || !id(event['cycle']) || event['delta'] is! int || (event['delta'] as int) < 0 || (event['delta'] as int) > maxQuantity ||
          event['item_id'] != null && !id(event['item_id']) || (event['delta'] as int) > 0 && event['item_id'] == null ||
          event.keys.any((k) => !{'event_id', 'type', 'item_id', 'buy_id', 'cycle', 'delta', 'order', 'actor', 'created_at'}.contains(k))) bad();
    } else if (type == 'reopen') {
      if (!id(event['buy_id']) || !id(event['cycle']) || !id(event['next_cycle']) ||
          event.keys.any((k) => !{'event_id', 'type', 'buy_id', 'cycle', 'next_cycle', 'order', 'actor', 'created_at'}.contains(k))) bad();
    } else { bad(); }
    return event;
  }

  /// 自动来源字段只能由订阅处理器创建；公开手动API不接受这些body字段。
  /// 这里只核验结构与确定性ID；网络导入还必须验证已认证charge来源。
  static Json decodeEntry(Object? encoded,{required String familyId,String? expectedId}) {
    Never bad()=>throw const FormatException('账目结构或自动来源无效');
    if(encoded is! String)bad();
    final parsed=decodeBackupJson(encoded);if(parsed is! Map)bad();final entry=Json.from(parsed);
    bool identifier(Object? value){if(value is! String)return false;final m=ids.firstMatch(value);return m!=null&&m.start==0&&m.end==value.length;}
    bool date(Object? value){if(value is! String||value.length!=10)return false;final parsed=DateTime.tryParse(value);return parsed!=null&&parsed.year>=1&&parsed.year<=9999&&calendarDate(parsed)==value;}
    if(!entryBaseFields.every(entry.containsKey)||entry.keys.any((k)=>!entryFields.contains(k))||
        entry['family_id']!=familyId||!identifier(entry['created_by'])||entry['created_at'] is! String||
        (entry['created_at'] as String).length>64||DateTime.tryParse(entry['created_at'] as String)?.isUtc!=true||
        !date(entry['calendar_date'])||entry['calendar_offset_minutes'] is! int||
        (entry['calendar_offset_minutes'] as int)<-1440||(entry['calendar_offset_minutes'] as int)>1440||
        entry['amount_minor'] is! int||(entry['amount_minor'] as int).abs()>maxMinor||
        entry['category'] is! String||(entry['category'] as String).length>16||!identifier(entry['category'])||
        entry['exclude_from_budget'] is! bool||entry['note']!=null&&(entry['note'] is! String||(entry['note'] as String).runes.length>200))bad();
    if(entrySourceFields.any(entry.containsKey)) {
      if(!entrySourceFields.every(entry.containsKey)||entry['source_plugin']!='subscription'||
          !identifier(entry['source_id'])||!date(entry['source_occurrence'])||
          entry['calendar_date']!=entry['source_occurrence']||
          entry['source_event_id']!=uuid.v5(namespace,'subscription-charge:$familyId:${entry['source_id']}:${entry['source_occurrence']}')||
          expectedId!=null&&expectedId!=uuid.v5(namespace,'subscription-expense:$familyId:${entry['source_id']}:${entry['source_occurrence']}'))bad();
    }
    return entry;
  }

  static Never invalid(String message) => throw ApiException(
      'VALIDATION_ERROR', message, statusCode: 400);
  static Never conflict(String message) => throw ApiException(
      'STOCK_QUANTITY_CONFLICT', message, statusCode: 409);
  static Never notFound() => throw ApiException(
      'NOT_FOUND', '记录不存在', statusCode: 404);
  static Never methodError() => throw ApiException(
      'METHOD_NOT_ALLOWED', '此记录不支持该操作', statusCode: 405);
  static void only(Json body, Set<String> allowed) {
    if (body.keys.any((key) => !allowed.contains(key))) invalid('包含未知或只读字段');
  }
  static String text(Object? value, int max, {bool empty = false}) {
    if (value is! String || (!empty && value.trim().isEmpty) || value.runes.length > max) invalid('文本为空或超过长度限制');
    return value.trim();
  }
  static String? nullableText(Object? value, int max) => value == null ? null : text(value, max, empty: true);
  static int integer(Object? value, int min, int max) {
    if (value is! int || value < min || value > max) invalid('数量必须为范围内整数');
    return value;
  }
  static bool boolean(Object? value) {
    if (value is! bool) invalid('开关值无效');
    return value;
  }
  static bool? filterBool(Object? value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value == 'true') return true;
    if (value == 'false') return false;
    invalid('筛选值无效');
  }
  String stable(String value) => uuid.v5(namespace, value);
  String col(String fid, String name) => '/families/$fid/plugins/stock/$name';

  Future<LocalResult?> request(String method, String fid, List<String> tail,
      {Json body = const {}, Json query = const {}}) async {
    if (tail.length < 2) return null;
    final stock = tail[0] == 'stock' && ['items', 'buys'].contains(tail[1]) && tail.length <= 4 &&
        (tail.length != 4 || (tail[1] == 'items' ? ['to-buy', 'adjust'] : ['bought', 'reopen']).contains(tail[3]));
    final accounting = tail[0] == 'accounting' && ['categories', 'transactions', 'budget', 'summary', 'receipt-scan'].contains(tail[1]) &&
        (tail.length == 2 || tail.length == 3 && tail[1] == 'transactions');
    if (!stock && !accounting) return null;
    if (!ids.hasMatch(fid) || (tail.length >= 3 && !ids.hasMatch(tail[2]))) invalid('记录标识无效');
    final verb = method.toUpperCase();
    // Read and write paths use the same SQLite snapshot. The builder appends
    // events and metadata in the transaction that checks balance/idempotency.
    late LocalResult result;
    await store.batchComputed((tx) async {
      final member = await _document(tx, fid, '/families/$fid/members', store.deviceId);
      if (member == null || member['status'] != 'active' || member['user_id'] != store.deviceId || member['family_id'] != fid) {
        throw ApiException('FORBIDDEN', '当前本机身份不是此家庭的有效成员', statusCode: 403);
      }
      final client = body['client_id'];
      final claimId = client == null || verb == 'GET' ? null : stable('${tail[0]}-client:$fid:${text(client, 100)}');
      final fingerprint = LocalStore.canonical({'method': verb, 'tail': tail, 'body': body, 'query': query});
      if (claimId != null) {
        final claim = await _document(tx, fid, '/families/$fid/plugins/${tail[0]}/requests', claimId);
        if (claim != null) {
          if (claim['fingerprint'] != fingerprint) conflict('同一 client_id 对应不同请求');
          result = (data: claim['response'], meta: null);
          return <Json>[];
        }
      }
      final changes = <Json>[];
      result = stock
        ? await _stock(tx, verb, fid, tail, body, query, await _StockState.load(tx, fid, col(fid, 'events')), changes)
        : await _accounting(tx, verb, fid, tail, body, query, changes);
      if (claimId != null) changes.add(_change(fid, '/families/$fid/plugins/${tail[0]}/requests', claimId,
        {'fingerprint': fingerprint, 'response': result.data}));
      return changes;
    });
    return result;
  }

  static Future<Json?> _document(DatabaseExecutor tx, String fid, String collection, String id,
      {bool includeDeleted = false}) async {
    final rows = await tx.query('documents', where: 'space=? AND collection=? AND id=?${includeDeleted ? '' : ' AND deleted=0'}', whereArgs: [fid, collection, id]);
    if (rows.isEmpty) return null;
    return {...Json.from(jsonDecode(rows.single['data'] as String) as Map), 'id': id,
      if (includeDeleted) 'deleted': rows.single['deleted'] == 1};
  }
  static Future<List<Json>> _documents(DatabaseExecutor tx, String fid, String collection) async {
    final rows = await tx.query('documents', where: 'space=? AND collection=? AND deleted=0', whereArgs: [fid, collection]);
    return [for (final row in rows) {...Json.from(jsonDecode(row['data'] as String) as Map), 'id': row['id']}];
  }
  Future<Json> _required(DatabaseExecutor tx, String fid, String collection, String id) async {
    final row = await _document(tx, fid, collection, id);
    if (row == null || row['family_id'] != fid) notFound();
    return row;
  }
  Future<Json> _author(DatabaseExecutor tx, String fid, Json row) async {
    final id = row['created_by'];
    final member = id is String ? await _document(tx, fid, '/families/$fid/members', id) : null;
    final active = member?['status'] == 'active' && member?['family_id'] == fid && member?['user_id'] == id;
    return {...row, 'creator_name': active ? member?['display_name'] : null,
      'creator_emoji': active ? member?['avatar_emoji'] : null,
      'creator_avatar_url': active ? member?['avatar_url'] : null};
  }
  Json _change(String fid, String collection, String id, Json fields, {bool delete = false}) =>
      {'space': fid, 'collection': collection, 'id': id, 'fields': fields, if (delete) 'delete': true};
  Json _values(Json body, {required bool item, required bool create}) {
    only(body, {if (item) ...['name', 'emoji', 'qty', 'unit', 'low_at', 'note', 'base_qty', 'confirm_stocktake']
      else ...['name', 'emoji', 'want_qty', 'note', 'bought'], 'client_id'});
    final out = <String, dynamic>{};
    for (final field in ['name', 'emoji']) {
      if (create || body.containsKey(field)) out[field] = text(body.containsKey(field) ? body[field] : (field == 'emoji' ? (item ? '📦' : '🛒') : null), field == 'name' ? 64 : 16);
    }
    for (final field in [if (item) 'unit' else 'want_qty', 'note']) {
      if (create || body.containsKey(field)) out[field] = nullableText(body[field], field == 'note' ? 500 : (item ? 16 : 32));
    }
    if (item && (create || body.containsKey('low_at'))) out['low_at'] = body['low_at'] == null ? null : integer(body['low_at'], 0, maxQuantity);
    if (body.containsKey('client_id')) text(body['client_id'], 100);
    return out;
  }
  Future<Json> _event(DatabaseExecutor tx, String fid, _StockState state,
      List<Json> changes, String eventId, Json payload) async {
    final semantic = LocalStore.canonical(payload);
    final existing = state.events.where((e) => e['event_id'] == eventId).toList();
    if (existing.isNotEmpty) {
      if (existing.any((e) => _StockState.semantic(e) != semantic)) conflict('同一重试标识对应不同操作，请确认后重试');
      return existing.first;
    }
    final clocks = await tx.query('meta', where: 'key=?', whereArgs: ['clock:$fid']);
    final clock = clocks.isEmpty ? 0 : jsonDecode(clocks.single['value'] as String) as int;
    final event = {...payload, 'event_id': eventId, 'order': clock + changes.length + 1,
      'actor': store.deviceId, 'created_at': now().toUtc().toIso8601String()};
    changes.add(_change(fid, col(fid, 'events'), eventId, {'event': LocalStore.canonical(event)}));
    state.events.add(event); return event;
  }
  String _operationId(String fid, String kind, String id, Json body) =>
      body['client_id'] == null ? uuid.v4() : stable('$fid:$kind:$id:${text(body['client_id'], 100)}');
  Future<Json> _itemRead(DatabaseExecutor tx, String fid, Json row, _StockState state) async {
    final id = row['id'] as String;
    final quantity = state.quantity(id);
    final conflicts = state.conflicts(id);
    return _author(tx, fid, {...row, 'qty': quantity, 'raw_qty': quantity,
      'quantity_conflict': quantity < 0 || quantity > maxQuantity || conflicts.isNotEmpty,
      'quantity_conflicts': conflicts,
      'is_low': row['low_at'] is int && quantity <= (row['low_at'] as int)});
  }
  Future<Json> _buyRead(DatabaseExecutor tx, String fid, Json row, _StockState state) async {
    final receipt = state.receipt(row['id'] as String);
    final linked = row['stock_item_id'];
    final target = linked is String ? await _document(tx, fid, col(fid, 'items'), linked) : null;
    return _author(tx, fid, {...row, 'bought': receipt.bought,
      'bought_at': receipt.bought ? receipt.at : null,
      'stock_item_id': target == null && !state.pendingItems.contains(linked) ? null : linked, 'purchase_cycle': receipt.cycle,
      'receipt_conflict': receipt.conflict});
  }

  Future<LocalResult> _stock(DatabaseExecutor tx, String verb, String fid,
      List<String> tail, Json body, Json query, _StockState state, List<Json> changes) async {
    final item = tail[1] == 'items';
    final collection = col(fid, tail[1]);
    if (tail.length == 2 && verb == 'GET') {
      only(query, {item ? 'low' : 'bought'});
      final filter = filterBool(query[item ? 'low' : 'bought']);
      final rows = <Json>[];
      for (final row in await _documents(tx, fid, collection)) {
        final read = item ? await _itemRead(tx, fid, row, state) : await _buyRead(tx, fid, row, state);
        if (item ? filter != true || read['is_low'] == true : filter == null || read['bought'] == filter) rows.add(read);
      }
      rows.sort((a, b) {
        if (!item && a['bought'] != b['bought']) return a['bought'] == true ? 1 : -1;
        final time = (b['created_at'] as String).compareTo(a['created_at'] as String);
        return time != 0 ? time : (a['id'] as String).compareTo(b['id'] as String);
      });
      return (data: rows, meta: null);
    }
    only(query, <String>{});
    if (tail.length == 2) {
      if (verb != 'POST') methodError();
      final values = _values(body, item: item, create: true);
      final id = _operationId(fid, 'create-${tail[1]}', 'new', body);
      final old = await _document(tx, fid, collection, id, includeDeleted: true);
      final fingerprint = LocalStore.canonical(body);
      if (old != null) {
        if (old['deleted'] == true || old['creation_request'] != fingerprint) conflict('同一重试标识已被使用或记录已删除');
        return (data: item ? await _itemRead(tx, fid, old, state) : await _buyRead(tx, fid, old, state), meta: null);
      }
      final row = {...values, 'id': id, 'family_id': fid, 'created_by': store.deviceId,
        'created_at': now().toUtc().toIso8601String(), 'creation_request': fingerprint,
        if (!item) 'stock_item_id': null};
      changes.add(_change(fid, collection, id, {...row}..remove('id')));
      if (item) await _event(tx, fid, state, changes, stable('initial:$fid:$id'),
          {'type': 'delta', 'item_id': id, 'delta': integer(body.containsKey('qty') ? body['qty'] : 0, 0, maxQuantity), 'ack': <String>[]});
      return (data: item ? await _itemRead(tx, fid, row, state) : await _buyRead(tx, fid, row, state), meta: null);
    }
    final row = await _required(tx, fid, collection, tail[2]);
    final id = row['id'] as String;
    if (tail.length == 3) {
      if (verb == 'GET') return (data: item ? await _itemRead(tx, fid, row, state) : await _buyRead(tx, fid, row, state), meta: null);
      if (verb == 'DELETE') {
        only(body, {'client_id'});
        changes.add(_change(fid, collection, id, {}, delete: true));
        return (data: {'deleted': id}, meta: null);
      }
      if (verb != 'PUT') methodError();
      final values = _values(body, item: item, create: false);
      if (item && body.containsKey('qty')) {
        final current = state.quantity(id);
        final target = integer(body['qty'], 0, maxQuantity);
        final hasConflict = current < 0 || current > maxQuantity || state.conflicts(id).isNotEmpty;
        final confirm = body.containsKey('confirm_stocktake') ? boolean(body['confirm_stocktake']) : false;
        if (hasConflict && !confirm) conflict('库存合并后数量冲突，请实际盘点后确认数量');
        final base = body.containsKey('base_qty') ? integer(body['base_qty'], 0, maxQuantity) : current;
        final delta = target - (confirm ? current : base);
        if (current + delta < 0 || current + delta > maxQuantity) conflict('库存数量不足或超过上限，未扣减');
        await _event(tx, fid, state, changes, _operationId(fid, 'adjust', id, body),
          {'type': 'delta', 'item_id': id, 'delta': delta, 'ack': confirm ? state.conflicts(id) : <String>[]});
      }
      if (values.isNotEmpty) changes.add(_change(fid, collection, id, values));
      final updated = {...row, ...values};
      if (!item && body.containsKey('bought')) {
        final bought = boolean(body['bought']);
        if (bought) await _receive(tx, fid, updated, {}, state, changes);
        else await _reopen(tx, fid, id, state, changes);
      }
      return (data: item ? await _itemRead(tx, fid, updated, state) : await _buyRead(tx, fid, updated, state), meta: null);
    }
    if (verb != 'POST') methodError();
    if (item && tail[3] == 'to-buy') {
      only(body, {'client_id'});
      final candidates = await _documents(tx, fid, col(fid, 'buys'));
      for (final buy in candidates) {
        if (buy['stock_item_id'] == id && !state.receipt(buy['id'] as String).bought) return (data: await _buyRead(tx, fid, buy, state), meta: null);
      }
      final history = await tx.query('documents', where: 'space=? AND collection=?', whereArgs: [fid, col(fid, 'buys')]);
      final previous = history.where((b) => (jsonDecode(b['data'] as String) as Map)['stock_item_id'] == id).map((b) => b['id'] as String).toList()..sort();
      final buyId = stable('to-buy:$fid:$id:${previous.join(':')}');
      if (await _document(tx, fid, col(fid, 'buys'), buyId, includeDeleted: true) != null) conflict('此采购轮次已删除，请手动新增采买');
      final buy = {'id': buyId, 'family_id': fid, 'name': row['name'], 'emoji': row['emoji'],
        'want_qty': row['unit'], 'note': null, 'stock_item_id': id,
        'created_at': now().toUtc().toIso8601String(), 'created_by': store.deviceId};
      changes.add(_change(fid, col(fid, 'buys'), buyId, {...buy}..remove('id')));
      return (data: await _buyRead(tx, fid, buy, state), meta: null);
    }
    if (!item && tail[3] == 'bought') {
      only(body, {'into_stock_qty', 'client_id'});
      await _receive(tx, fid, row, body, state, changes);
      return (data: await _buyRead(tx, fid, row, state), meta: null);
    }
    if (!item && tail[3] == 'reopen') {
      only(body, {'client_id'}); await _reopen(tx, fid, id, state, changes);
      return (data: await _buyRead(tx, fid, row, state), meta: null);
    }
    if (item && tail[3] == 'adjust') {
      only(body, {'delta_qty', 'client_id'});
      final delta = integer(body['delta_qty'], -maxQuantity, maxQuantity);
      final current = state.quantity(id);
      if (current < 0 || current > maxQuantity || state.conflicts(id).isNotEmpty || current + delta < 0 || current + delta > maxQuantity) conflict('库存不足或存在待盘点冲突，未改变数量');
      await _event(tx, fid, state, changes, _operationId(fid, 'adjust', id, body), {'type': 'delta', 'item_id': id, 'delta': delta, 'ack': <String>[]});
      return (data: await _itemRead(tx, fid, row, state), meta: null);
    }
    methodError();
  }

  Future<void> _receive(DatabaseExecutor tx, String fid, Json buy, Json body,
      _StockState state, List<Json> changes) async {
    final id = buy['id'] as String;
    final receipt = state.receipt(id);
    final amount = body['into_stock_qty'] == null ? 0 : integer(body['into_stock_qty'], 0, maxQuantity);
    if (receipt.bought) {
      if (body.containsKey('into_stock_qty') && amount != receipt.amount) conflict('此轮已确认收货，不能重复入库不同数量');
      return;
    }
    String? target;
    if (amount > 0) {
      target = buy['stock_item_id'] as String? ?? stable('received-stock:$fid:$id');
      final existing = await _document(tx, fid, col(fid, 'items'), target, includeDeleted: true);
      if (existing?['deleted'] == true || (buy['stock_item_id'] != null && existing == null)) conflict('关联库存已删除，未复活记录或自动入库');
      if (existing == null) {
        state.pendingItems.add(target);
        changes.add(_change(fid, col(fid, 'items'), target, {'family_id': fid, 'name': buy['name'],
          'emoji': buy['emoji'], 'unit': null, 'note': null, 'low_at': null,
          'created_by': store.deviceId, 'created_at': now().toUtc().toIso8601String()}));
      }
      final current = state.quantity(target);
      if (current < 0 || current + amount > maxQuantity || state.conflicts(target).isNotEmpty) conflict('入库目标存在冲突或超过数量上限');
      buy['stock_item_id'] = target;
      changes.add(_change(fid, col(fid, 'buys'), id, {'stock_item_id': target}));
    }
    await _event(tx, fid, state, changes, stable('receipt:$fid:$id:${receipt.cycle}'),
      {'type': 'receipt', 'buy_id': id, 'cycle': receipt.cycle, 'item_id': target, 'delta': amount});
  }
  Future<void> _reopen(DatabaseExecutor tx, String fid, String id,
      _StockState state, List<Json> changes) async {
    final receipt = state.receipt(id);
    if (!receipt.bought) return;
    await _event(tx, fid, state, changes, stable('reopen:$fid:$id:${receipt.cycle}'),
      {'type': 'reopen', 'buy_id': id, 'cycle': receipt.cycle,
        'next_cycle': stable('next-cycle:$fid:$id:${receipt.cycle}')});
  }

  static const maxMinor = 999999999999;
  static const safeMinor = 9007199254740991;
  static const builtinCategories = <Json>[
    {'code': 'dining', 'label': '餐饮', 'emoji': '🍜'},
    {'code': 'snack', 'label': '零食', 'emoji': '🍭'},
    {'code': 'shopping', 'label': '购物', 'emoji': '🛍️'},
    {'code': 'utilities', 'label': '水电', 'emoji': '💡'},
    {'code': 'car', 'label': '养车', 'emoji': '🚗'},
    {'code': 'pet', 'label': '宠物', 'emoji': '🐾'},
    {'code': 'subscription', 'label': '软件/订阅', 'emoji': '💳'},
  ];
  String _acctCol(String fid, String resource) => '/families/$fid/plugins/accounting/$resource';

  /// Parse decimal text into cents; never multiply a binary floating value.
  static int moneyMinor(Object? value, {bool nonnegative = false}) {
    if (value is! String && value is! num || value is num && !value.isFinite) invalid('金额必须为有限十进制数');
    final source = value.toString();
    if (!RegExp(r'^-?[0-9]{1,10}(\.[0-9]{1,2})?$').hasMatch(source)) invalid('金额最多两位小数且不能超过金额上限');
    final negative = source.startsWith('-');
    final parts = (negative ? source.substring(1) : source).split('.');
    final minor = int.parse(parts[0]) * 100 + (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
    if (minor > maxMinor || nonnegative && negative && minor != 0) invalid('金额超出范围');
    return negative ? -minor : minor;
  }
  static String moneyText(int minor) => '${minor < 0 ? '-' : ''}${minor.abs() ~/ 100}.${(minor.abs() % 100).toString().padLeft(2, '0')}';
  static String calendarDate(DateTime date) => '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  static String _validDate(Object? date) {
    if (date is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) invalid('账期日期无效');
    final parsed = DateTime.tryParse(date);
    if (parsed == null || parsed.year < 1 || parsed.year > 9999 || calendarDate(parsed) != date) invalid('账期日期无效');
    return date;
  }
  ({int year, int month})? _period(Json query, {required bool defaults}) {
    only(query, {'year', 'month'});
    if (query.isEmpty) {
      if (!defaults) return null;
      final today = now().toLocal(); return (year: today.year, month: today.month);
    }
    int parse(Object? input, int min, int max) {
      if (input is String && RegExp(r'^\d+$').hasMatch(input)) input = int.tryParse(input);
      return integer(input, min, max);
    }
    return (year: parse(query['year'], 1, 9999), month: parse(query['month'], 1, 12));
  }
  List<Json> _periodRows(List<Json> rows, ({int year, int month})? period) {
    if (period == null) return rows;
    final prefix = '${period.year.toString().padLeft(4, '0')}-${period.month.toString().padLeft(2, '0')}-';
    return rows.where((row) => (row['calendar_date'] as String).startsWith(prefix)).toList();
  }
  Future<List<Json>> _categories(DatabaseExecutor tx, String fid) async {
    final rows = await _documents(tx, fid, _acctCol(fid, 'categories'));
    rows.sort((a, b) {
      final date = (a['created_at'] as String).compareTo(b['created_at'] as String);
      return date != 0 ? date : (a['id'] as String).compareTo(b['id'] as String);
    });
    return [...builtinCategories, for (final row in rows) {'code': row['id'], 'label': row['label'], 'emoji': row['emoji']}];
  }
  Future<void> _category(DatabaseExecutor tx, String fid, Object? code) async {
    if (code is! String || code.length > 16 || !(await _categories(tx, fid)).any((c) => c['code'] == code)) {
      throw ApiException('VALIDATION_ERROR', '分类不存在，请重新选择', statusCode: 422);
    }
  }
  Json _entry(Json row) {
    Json entry;
    try {entry=decodeEntry(row['entry'],familyId:row['family_id'] as String,expectedId:row['id'] as String);}
    on FormatException {throw ApiException('ACCOUNTING_INVALID','账目金额或来源无效',statusCode:409);}
    return {...entry,'id':row['id'],'amount':moneyText(entry['amount_minor'] as int)};
  }
  Future<int?> _budget(DatabaseExecutor tx, String fid) async {
    final row = await _document(tx, fid, _acctCol(fid, 'budget'), 'monthly');
    if (row == null) return null;
    final entry = Json.from(jsonDecode(row['entry'] as String) as Map);
    final minor = entry['monthly_amount_minor'];
    if (minor is! int || minor < 0 || minor > maxMinor) throw ApiException('ACCOUNTING_INVALID', '本地预算无效', statusCode: 409);
    return minor;
  }
  static int _sumMinor(int left, int right) {
    if (left.abs() > safeMinor || right.abs() > safeMinor || (left + right).abs() > safeMinor) invalid('汇总金额超过安全整数范围');
    return left + right;
  }

  Future<LocalResult> _accounting(DatabaseExecutor tx, String verb, String fid,
      List<String> tail, Json body, Json query, List<Json> changes) async {
    final resource = tail[1];
    final collection = _acctCol(fid, resource);
    if (resource == 'receipt-scan') {
      if (verb != 'POST') methodError();
      throw ApiException('FEATURE_UNAVAILABLE', '本机小票识别尚未接入，请手动填写未保存草稿', statusCode: 501);
    }
    if (resource == 'categories') {
      only(query, <String>{});
      if (verb == 'GET') return (data: await _categories(tx, fid), meta: null);
      if (verb != 'POST') methodError();
      only(body, {'label', 'emoji', 'client_id'});
      final label = text(body['label'], 20);
      final emoji = text(body.containsKey('emoji') ? body['emoji'] : '💰', 16);
      if ((await _categories(tx, fid)).any((c) => c['label'] == label)) throw ApiException('VALIDATION_ERROR', '分类名称已存在', statusCode: 422);
      final code = 'c_${stable('accounting-category:$fid:$label').replaceAll('-', '').substring(0, 14)}';
      changes.add(_change(fid, collection, code, {'family_id': fid, 'label': label, 'emoji': emoji, 'created_at': now().toUtc().toIso8601String()}));
      return (data: {'code': code, 'label': label, 'emoji': emoji}, meta: null);
    }
    if (resource == 'budget') {
      only(query, <String>{});
      if (verb == 'GET') { final amount = await _budget(tx, fid); return (data: {'monthly_amount': amount == null ? null : moneyText(amount)}, meta: null); }
      if (verb != 'PUT') methodError();
      only(body, {'monthly_amount', 'client_id'});
      final minor = moneyMinor(body['monthly_amount'], nonnegative: true);
      changes.add(_change(fid, collection, 'monthly', {'family_id': fid, 'entry': LocalStore.canonical({
        'monthly_amount_minor': minor, 'updated_at': now().toUtc().toIso8601String(), 'updated_by': store.deviceId})}));
      return (data: {'monthly_amount': moneyText(minor)}, meta: null);
    }
    if (resource == 'summary') {
      if (verb != 'GET') methodError();
      final period = _period(query, defaults: true);
      final entries = _periodRows([for (final row in await _documents(tx, fid, _acctCol(fid, 'transactions'))) _entry(row)], period);
      var total = 0, excluded = 0, budgeted = 0;
      for (final entry in entries) {
        final amount = entry['amount_minor'] as int;
        total = _sumMinor(total, amount);
        if (entry['exclude_from_budget'] == true) excluded = _sumMinor(excluded, amount);
        else budgeted = _sumMinor(budgeted, amount);
      }
      final budget = await _budget(tx, fid);
      return (data: {'month_total': moneyText(total), 'budgeted_total': moneyText(budgeted),
        'excluded_total': moneyText(excluded), 'budget': budget == null ? null : moneyText(budget),
        'remaining': budget == null ? null : moneyText(_sumMinor(budget, -budgeted))}, meta: null);
    }
    if (tail.length == 2 && verb == 'GET') {
      final period = _period(query, defaults: false);
      final entries = _periodRows([for (final row in await _documents(tx, fid, collection)) _entry(row)], period);
      entries.sort((a, b) {
        final date = (b['created_at'] as String).compareTo(a['created_at'] as String);
        return date != 0 ? date : (a['id'] as String).compareTo(b['id'] as String);
      });
      return (data: [for (final entry in entries) await _author(tx, fid, entry)], meta: null);
    }
    only(query, <String>{});
    if (tail.length == 3 && verb == 'DELETE') {
      await _required(tx, fid, collection, tail[2]); only(body, {'client_id'});
      changes.add(_change(fid, collection, tail[2], {}, delete: true));
      return (data: {'deleted': tail[2]}, meta: null);
    }
    if (tail.length == 3 && verb == 'GET') return (data: await _author(tx, fid, _entry(await _required(tx, fid, collection, tail[2]))), meta: null);
    if (tail.length == 2 ? verb != 'POST' : verb != 'PUT') methodError();
    only(body, {'amount', 'category', 'note', 'exclude_from_budget', 'client_id'});
    final create = tail.length == 2;
    final id = create ? _operationId(fid, 'accounting-create', 'new', body) : tail[2];
    Json entry;
    if (create) {
      final clock = now().toLocal();
      entry = {'family_id': fid, 'created_by': store.deviceId,
        'created_at': clock.toUtc().toIso8601String(), 'calendar_date': calendarDate(clock),
        'calendar_offset_minutes': clock.timeZoneOffset.inMinutes,
        'note': null, 'exclude_from_budget': false};
    } else { entry = _entry(await _required(tx, fid, collection, id))..remove('id')..remove('amount'); }
    if (create || body.containsKey('amount')) entry['amount_minor'] = moneyMinor(body['amount']);
    if (create || body.containsKey('category')) { await _category(tx, fid, body['category']); entry['category'] = body['category']; }
    if (body.containsKey('note')) entry['note'] = nullableText(body['note'], 200);
    if (body.containsKey('exclude_from_budget')) entry['exclude_from_budget'] = boolean(body['exclude_from_budget']);
    changes.add(_change(fid, collection, id, {'family_id': fid, 'entry': LocalStore.canonical(entry)}));
    return (data: await _author(tx, fid, {...entry, 'id': id, 'amount': moneyText(entry['amount_minor'] as int)}), meta: null);
  }
}

/// Merge-order independent reducer. Source events are read from the immutable
/// operations log, so a colliding document ID cannot hide a different payload.
class _StockState {
  _StockState(this.events);
  final List<Json> events;
  final Set<String> pendingItems = {};
  static String semantic(Json event) => StockAccountingRoutes.eventSemantic(event);
  static Future<_StockState> load(DatabaseExecutor tx, String fid, String collection) async {
    final rows = await tx.query('operations', columns: ['payload'], where: 'space=?', whereArgs: [fid]);
    final events = <Json>[];
    for (final row in rows) {
      final operation = Json.from(jsonDecode(row['payload'] as String) as Map);
      if (operation['collection'] != collection) continue;
      final fields = operation['fields'];
      if (operation['kind'] != 'patch' || fields is! Map || fields['event'] is! String) throw ApiException('STOCK_LEDGER_INVALID', '库存事件不可修改或删除', statusCode: 409);
      try {
        if (fields.length != 1) throw const FormatException('库存事件字段无效');
        events.add(StockAccountingRoutes.decodeEvent(fields['event'], expectedId: operation['id'] as String,
          actor: operation['actor'] as String, order: operation['clock'] as int));
      } on FormatException { throw ApiException('STOCK_LEDGER_INVALID', '库存事件来源或数量无效', statusCode: 409); }
    }
    return _StockState(events);
  }
  List<Json> get canonicalEvents {
    final sorted = [...events]..sort((a, b) {
      final order = (a['order'] as int).compareTo(b['order'] as int);
      final actor = (a['actor'] as String).compareTo(b['actor'] as String);
      return order != 0 ? order : actor != 0 ? actor : (a['event_id'] as String).compareTo(b['event_id'] as String);
    });
    final seen = <String>{};
    return [for (final e in sorted) if (seen.add(e['event_id'] as String)) e];
  }
  int quantity(String item) {
    var sum = 0;
    for (final event in canonicalEvents.where((e) => e['item_id'] == item && ['delta', 'receipt'].contains(e['type']))) {
      sum += event['delta'] as int;
      if (sum.abs() > StockAccountingRoutes.safeMinor) throw ApiException('STOCK_LEDGER_LIMIT', '库存账本超过安全整数范围，未截断数量', statusCode: 409);
    }
    return sum;
  }
  List<String> conflicts(String item) {
    final grouped = <String, Set<String>>{};
    final acknowledged = <String>{};
    final relevant = events.where((e) => e['item_id'] == item).map((e) => e['event_id'] as String).toSet();
    for (final event in events) {
      if (relevant.contains(event['event_id'])) grouped.putIfAbsent(event['event_id'] as String, () => {}).add(semantic(event));
      if (event['item_id'] == item && event['type'] == 'delta' && event['ack'] is List) acknowledged.addAll((event['ack'] as List).cast<String>());
    }
    return [for (final group in grouped.entries) if (group.value.length > 1)
      for (final variant in group.value) if (!acknowledged.contains('${group.key}:$variant')) '${group.key}:$variant']..sort();
  }
  ({String cycle, bool bought, String? at, int amount, bool conflict}) receipt(String buy) {
    var cycle = 'initial'; var bought = false; String? at; var amount = 0;
    for (final event in canonicalEvents.where((e) => e['buy_id'] == buy)) {
      if (event['cycle'] != cycle) continue;
      if (event['type'] == 'receipt') { bought = true; at = event['created_at'] as String; amount = event['delta'] as int; }
      if (event['type'] == 'reopen' && bought) { cycle = event['next_cycle'] as String; bought = false; at = null; amount = 0; }
    }
    final grouped = <String, Set<String>>{};
    for (final e in events.where((e) => e['buy_id'] == buy)) grouped.putIfAbsent(e['event_id'] as String, () => {}).add(semantic(e));
    var unresolved = false;
    for (final group in grouped.entries.where((g) => g.value.length > 1)) {
      final targets = events.where((e) => e['event_id'] == group.key && e['item_id'] is String).map((e) => e['item_id'] as String).toSet();
      if (targets.isEmpty || targets.any((target) => conflicts(target).any((c) => c.startsWith('${group.key}:')))) unresolved = true;
    }
    return (cycle: cycle, bought: bought, at: at, amount: amount, conflict: unresolved);
  }
}
