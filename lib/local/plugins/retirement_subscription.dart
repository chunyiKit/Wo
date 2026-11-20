import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../local_backend.dart';
import '../local_store.dart';
import 'stock_accounting.dart';

/// Pure local financial records. processDue is an explicit foreground pass;
/// notifications are requests awaiting local delivery, never delivery receipts.
class RetirementSubscriptionRoutes {
  RetirementSubscriptionRoutes(this.store, {DateTime Function()? now}) : now = now ?? DateTime.now;
  final LocalStore store;
  final DateTime Function() now;
  static const _uuid = Uuid();
  static const _namespace = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';
  static const maxMinor = 99999999999999;
  static const safeInteger = 9007199254740991;
  static const syncFields = <String, Set<String>>{
    'plugins/retirement/accounts': {'family_id', 'entry'},
    'plugins/retirement/debts': {'family_id', 'entry'},
    'plugins/retirement/plan': {'family_id', 'entry'},
    'plugins/retirement/ledger': {'event'},
    'plugins/subscription/subscriptions': {'family_id', 'entry'},
    'plugins/subscription/charges': {'event'},
    'plugins/retirement/requests': {'fingerprint', 'response'},
    'plugins/subscription/requests': {'fingerprint', 'response'},
    'notifications': {'type', 'title', 'body', 'icon_emoji', 'created_by', 'created_at', 'read_by', 'status', 'recipient_ids', 'source_plugin', 'source_id'},
  };
  static const immutableCollections = {'plugins/retirement/ledger', 'plugins/subscription/charges'};
  static const eventFields = {'event_id', 'kind', 'account_id', 'debt_id', 'subscription_id', 'amount_minor', 'period', 'expense_period', 'due', 'next_due_after', 'auto_recorded', 'accounting_category', 'exclude_from_budget', 'note', 'actor', 'order', 'created_at'};
  static const eventSemanticFields = {'kind', 'account_id', 'debt_id', 'subscription_id', 'amount_minor', 'period', 'expense_period', 'due', 'next_due_after', 'auto_recorded', 'accounting_category', 'exclude_from_budget'};
  static const accountEntryFields = {'name', 'kind', 'emoji', 'balance_minor', 'monthly_income_minor', 'income_day', 'family_id', 'created_at', 'created_by', 'created_on', 'basis_event_ids', 'acknowledged_conflicts', 'settlement_checks'};
  static const debtEntryFields = {'name', 'kind', 'emoji', 'balance_minor', 'monthly_payment_minor', 'payment_day', 'active', 'from_account_id', 'family_id', 'created_at', 'created_by', 'created_on', 'basis_event_ids', 'acknowledged_conflicts'};
  static const planEntryFields = {'retire_date', 'savings_goal_minor', 'goal_basis', 'surplus_basis', 'updated_by', 'updated_at'};
  static const subscriptionEntryFields = {'name', 'emoji', 'amount_minor', 'cycle', 'next_due', 'note', 'notify_enabled', 'notify_days_before', 'auto_record', 'accounting_category', 'exclude_from_budget', 'active', 'family_id', 'created_by', 'created_at', 'created_on', 'acknowledged_charge_conflicts'};

  static const requestResponseFields = <String>{...accountEntryFields, ...debtEntryFields,
    ...planEntryFields, ...subscriptionEntryFields, 'id', 'balance', 'balance_conflict',
    'monthly_income', 'monthly_payment', 'settlement_conflict', 'savings_goal', 'creator_name', 'creator_emoji',
    'creator_avatar_url', 'amount', 'days_until', 'billing_conflict', 'conflict_frontier', 'deleted'};
  static String eventSemantic(Json event) => LocalStore.canonical({for (final key in eventSemanticFields) if (event.containsKey(key)) key: event[key]});
  static Json decodeEvent(Object? encoded, {String? expectedId, String? actor, int? order, bool? subscription}) {
    Never bad() => throw const FormatException('财务事件结构、金额或来源无效');
    if (encoded is! String) bad();
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) bad();
    final event = Json.from(decoded);
    bool identifier(Object? value) => value is String && StockAccountingRoutes.ids.hasMatch(value);
    if (event.keys.any((key) => !eventFields.contains(key)) || !identifier(event['event_id']) || !identifier(event['actor']) ||
        event['order'] is! int || (event['order'] as int) < 1 ||
        expectedId != null && event['event_id'] != expectedId || actor != null && event['actor'] != actor || order != null && event['order'] != order ||
        event['amount_minor'] is! int || (event['amount_minor'] as int).abs() > safeInteger ||
        event['created_at'] is! String || DateTime.tryParse(event['created_at'] as String)?.isUtc != true ||
        event['period'] is! String || !RegExp(r'^[0-9]{4}-(0[1-9]|1[0-2])$').hasMatch(event['period'] as String) ||
        int.parse((event['period'] as String).substring(0, 4)) < 1) bad();
    if (event['note'] != null && (event['note'] is! String || (event['note'] as String).runes.length > 200)) bad();
    final kind = event['kind'], amount = event['amount_minor'] as int;
    if (subscription != null && subscription != (kind == 'subscription_charge')) bad();
    if (kind == 'subscription_charge') {
      if (!identifier(event['subscription_id']) || amount <= 0 || amount > StockAccountingRoutes.maxMinor || event['auto_recorded'] is! bool || event['accounting_category'] is! String || (event['accounting_category'] as String).isEmpty || (event['accounting_category'] as String).length > 16 || event['exclude_from_budget'] is! bool) bad();
      final due = day(event['due']), next = day(event['next_due_after']);
      if (!next.isAfter(due) || period(due) != event['period'] || event.keys.any((k) => !{'event_id', 'kind', 'subscription_id', 'amount_minor', 'period', 'due', 'next_due_after', 'auto_recorded', 'accounting_category', 'exclude_from_budget', 'note', 'actor', 'order', 'created_at'}.contains(k))) bad();
    } else if (kind == 'income' || kind == 'debt_payment' || kind == 'expense_settle') {
      if (event['account_id'] != null && !identifier(event['account_id']) || event['debt_id'] != null && !identifier(event['debt_id'])) bad();
      if (kind == 'income' && (!identifier(event['account_id']) || event['debt_id'] != null || amount <= 0 || amount > maxMinor)) bad();
      if (kind == 'debt_payment' && (!identifier(event['debt_id']) || amount <= 0 || amount > maxMinor)) bad();
      if (kind == 'expense_settle') {
        if (event['debt_id'] != null || event['account_id'] != null && amount <= 0 || event['expense_period'] != previousPeriod(day('${event['period']}-01'))) bad();
      }
      if (event.keys.any((k) => !{'event_id', 'kind', 'account_id', 'debt_id', 'amount_minor', 'period', if (kind == 'expense_settle') 'expense_period', 'note', 'actor', 'order', 'created_at'}.contains(k))) bad();
    } else { bad(); }
    return event;
  }

  static const accountKinds = {'deposit', 'fund'};
  static const debtKinds = {'mortgage', 'car', 'other'};
  static const goalBases = {'net_worth', 'total_assets', 'deposit_only'};
  static const surplusBases = {'income_debt_expense', 'income_debt', 'income_only'};
  static Never _bad(String message, [int status = 400]) => throw ApiException(
      status == 403 ? 'FORBIDDEN' : status == 404 ? 'NOT_FOUND' : status == 405 ? 'METHOD_NOT_ALLOWED' : status == 409 ? 'LOCAL_FINANCIAL_CONFLICT' : 'VALIDATION_ERROR', message, statusCode: status);
  static void _only(Json value, Set<String> fields) { if (value.keys.any((k) => !fields.contains(k))) _bad('包含未知或只读字段'); }
  static String _text(Object? value, int max) => StockAccountingRoutes.text(value, max);
  static int _int(Object? value, int min, int max) => StockAccountingRoutes.integer(value, min, max);
  static bool _bool(Object? value) => StockAccountingRoutes.boolean(value);
  static String _enum(Object? value, Set<String> allowed) { if (value is! String || !allowed.contains(value)) _bad('类型或计算口径无效'); return value; }
  static String _id(Object? value) { if (value is! String || !StockAccountingRoutes.ids.hasMatch(value)) _bad('标识无效'); return value; }
  static int minor(Object? value, {bool nonnegative = false, bool subscription = false}) {
    if (value is! String && value is! num || value is num && !value.isFinite) _bad('金额必须是有限十进制数');
    final source = value.toString();
    if (!RegExp(r'^-?[0-9]{1,12}(\.[0-9]{1,2})?$').hasMatch(source)) _bad('金额最多两位小数');
    final negative = source.startsWith('-');
    final parts = (negative ? source.substring(1) : source).split('.');
    final amount = int.parse(parts[0]) * 100 + (parts.length > 1 ? int.parse(parts[1].padRight(2, '0')) : 0);
    if (amount > (subscription ? StockAccountingRoutes.maxMinor : maxMinor) || nonnegative && negative && amount != 0) _bad('金额超出范围');
    return negative ? -amount : amount;
  }
  static String money(int amount) => StockAccountingRoutes.moneyText(amount);
  static int sum(int a, int b) { final result = a + b; if (result.abs() > safeInteger) _bad('金额汇总超出安全整数范围', 409); return result; }
  static String date(DateTime day) => StockAccountingRoutes.calendarDate(day);
  static DateTime day(Object? input) {
    if (input is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(input)) _bad('日期必须为 YYYY-MM-DD');
    final value = DateTime.tryParse(input);
    if (value == null || value.year < 1 || value.year > 9999 || date(value) != input) _bad('日期不存在');
    return DateTime.utc(value.year, value.month, value.day);
  }
  DateTime get today { final value = now().toLocal(); return DateTime.utc(value.year, value.month, value.day); }
  static String period(DateTime value) => '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}';
  static String previousPeriod(DateTime value) => period(DateTime.utc(value.year, value.month - 1, 1));
  static String advanceDue(String current, String cycle) {
    _enum(cycle, {'monthly', 'yearly'});
    final value = day(current);
    final next = cycle == 'yearly' ? DateTime.utc(value.year + 1, value.month, 1) : DateTime.utc(value.year, value.month + 1, 1);
    if (next.year > 9999) _bad('到期日期超过支持范围');
    final last = DateTime.utc(next.year, next.month + 1, 0).day;
    return date(DateTime.utc(next.year, next.month, value.day < last ? value.day : last));
  }
  static int ceilDivide(int numerator, int denominator) => (numerator + denominator - 1) ~/ denominator;
  /// Decimal's default ROUND_HALF_EVEN, expressed entirely in integer cents.
  static int halfEvenDivide(int numerator, int denominator) {
    final quotient = numerator ~/ denominator, remainder = numerator % denominator;
    return quotient + (remainder * 2 > denominator || remainder * 2 == denominator && quotient.isOdd ? 1 : 0);
  }
  String stable(String name) => _uuid.v5(_namespace, name);
  String col(String fid, String plugin, String resource) => '/families/$fid/plugins/$plugin/$resource';
  Json change(String fid, String collection, String id, Json fields, {bool delete = false}) => {'space': fid, 'collection': collection, 'id': id, 'fields': fields, if (delete) 'delete': true};
  static Future<Json?> _doc(DatabaseExecutor tx, String fid, String collection, String id) async {
    final rows = await tx.query('documents', where: 'space=? AND collection=? AND id=? AND deleted=0', whereArgs: [fid, collection, id]);
    return rows.isEmpty ? null : {...Json.from(jsonDecode(rows.single['data'] as String) as Map), 'id': id};
  }
  static Future<List<Json>> _rows(DatabaseExecutor tx, String fid, String collection) async {
    final rows = await tx.query('documents', where: 'space=? AND collection=? AND deleted=0', whereArgs: [fid, collection]);
    return [for (final row in rows) {...Json.from(jsonDecode(row['data'] as String) as Map), 'id': row['id']}];
  }
  static Json _entry(Json row) {
    if (row['entry'] is! String) _bad('本地财务记录不完整', 409);
    final value = Json.from(jsonDecode(row['entry'] as String) as Map);
    if (value['family_id'] != null && value['family_id'] != row['family_id']) _bad('本地财务记录跨家庭', 409);
    return {...value, 'id': row['id']};
  }
  Future<void> _member(DatabaseExecutor tx, String fid) async {
    _id(fid);
    final row = await _doc(tx, fid, '/families/$fid/members', store.deviceId);
    if (row == null || row['user_id'] != store.deviceId || row['family_id'] != fid || row['status'] != 'active') _bad('本机没有此家庭的有效成员权限', 403);
  }
  Future<Json> _author(DatabaseExecutor tx, String fid, Json row) async {
    final creator = row['created_by'];
    final member = creator is String ? await _doc(tx, fid, '/families/$fid/members', creator) : null;
    final visible = member?['status'] == 'active' && member?['family_id'] == fid && member?['user_id'] == creator;
    return {...row, 'creator_name': visible ? member?['display_name'] : null,
      'creator_emoji': visible ? member?['avatar_emoji'] : null, 'creator_avatar_url': visible ? member?['avatar_url'] : null};
  }
  Future<Json> _required(DatabaseExecutor tx, String fid, String plugin, String resource, String id) async {
    final row = await _doc(tx, fid, col(fid, plugin, resource), _id(id));
    if (row == null || row['family_id'] != fid) _bad('记录不存在', 404);
    return _entry(row);
  }
  Future<List<Json>> _entries(DatabaseExecutor tx, String fid, String plugin, String resource) async =>
      [for (final row in await _rows(tx, fid, col(fid, plugin, resource))) _entry(row)];
  Future<bool> _installed(DatabaseExecutor tx, String fid, String plugin, {bool enabled = false}) async =>
      (await _rows(tx, fid, '/families/$fid/installed')).any((row) => row['plugin_id'] == plugin && (!enabled || row['enabled'] == true));
  Future<void> _category(DatabaseExecutor tx, String fid, Object? code) async {
    if (code is! String || code.length > 16 || !StockAccountingRoutes.builtinCategories.any((c) => c['code'] == code) &&
        await _doc(tx, fid, col(fid, 'accounting', 'categories'), code) == null) _bad('记账分类不存在', 422);
  }

  Future<LocalResult?> request(String method, String fid, List<String> tail,
      {Json body = const {}, Json query = const {}}) async {
    if (tail.length < 2) return null;
    final plugin = tail[0], resource = tail[1];
    final subscription = plugin == 'subscription' && resource == 'subscriptions' && tail.length <= 3;
    final retirement = plugin == 'retirement' && ['accounts', 'debts', 'plan', 'dashboard', 'ledger'].contains(resource) &&
        (tail.length == 2 || tail.length == 3 && ['accounts', 'debts'].contains(resource));
    if (!subscription && !retirement) return null;
    if (tail.length == 3) _id(tail[2]);
    final verb = method.toUpperCase();
    late LocalResult result;
    await store.batchComputed((tx) async {
      await _member(tx, fid);
      final changes = <Json>[];
      if (body.containsKey('expected_conflict_frontier') && (body['expected_conflict_frontier'] is! String || !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(body['expected_conflict_frontier'] as String))) _bad('确认版本无效，请重新读取记录', 409);
      final client = body['client_id'];
      final claimId = verb == 'GET' || client == null ? null : stable('$plugin-client:$fid:${_text(client, 100)}');
      final fingerprint = LocalStore.canonical({'method': verb, 'tail': tail, 'body': body, 'query': query});
      if (claimId != null) {
        final claim = await _doc(tx, fid, col(fid, plugin, 'requests'), claimId);
        if (claim != null) {
          if (claim['fingerprint'] != fingerprint) _bad('client_id 不可复用到不同请求', 409);
          result = (data: claim['response'], meta: null); return <Json>[];
        }
      }
      final state = await _FinancialEvents.load(tx, fid);
      result = subscription
        ? await _subscription(tx, verb, fid, tail, body, query, state, changes)
        : await _retirement(tx, verb, fid, tail, body, query, state, changes);
      if (claimId != null) changes.add(change(fid, col(fid, plugin, 'requests'), claimId, {'fingerprint': fingerprint, 'response': result.data}));
      return changes;
    });
    return result;
  }

  Future<Json> _accountRead(DatabaseExecutor tx, String fid, Json entry, _FinancialEvents state, {bool debt = false}) async {
    final id = entry['id'] as String;
    final balance = state.balance(entry, debt: debt);
    final linked = entry['from_account_id'];
    final target = linked is String ? await _doc(tx, fid, col(fid, 'retirement', 'accounts'), linked) : null;
    return _author(tx, fid, {...entry, 'balance': money(balance),
      'conflict_frontier': await _frontier(tx, fid, 'retirement', debt ? 'debts' : 'accounts', entry, state),
      'balance_conflict': state.conflicts(entry).isNotEmpty || debt && balance < 0 || !debt && await _settlementConflict(tx, fid, entry, state),
      if (!debt) 'settlement_conflict': await _settlementConflict(tx, fid, entry, state),
      if (debt) ...{'monthly_payment': money(entry['monthly_payment_minor'] as int), 'active': entry['active'] == true && balance > 0,
        'from_account_id': target == null ? null : linked}
      else 'monthly_income': money(entry['monthly_income_minor'] as int)});
  }
  Json _planRead(Json entry) => {'retire_date': entry['retire_date'],
    'savings_goal': entry['savings_goal_minor'] == null ? null : money(entry['savings_goal_minor'] as int),
    'goal_basis': entry['goal_basis'] ?? 'net_worth', 'surplus_basis': entry['surplus_basis'] ?? 'income_debt_expense'};
  Future<Json> _plan(DatabaseExecutor tx, String fid) async {
    final row = await _doc(tx, fid, col(fid, 'retirement', 'plan'), 'family');
    return row == null ? {'retire_date': null, 'savings_goal_minor': null, 'goal_basis': 'net_worth', 'surplus_basis': 'income_debt_expense'} : _entry(row);
  }

  Future<LocalResult> _retirement(DatabaseExecutor tx, String verb, String fid, List<String> tail,
      Json body, Json query, _FinancialEvents state, List<Json> changes) async {
    final resource = tail[1];
    if (resource == 'ledger') {
      if (verb != 'GET') _bad('流水为只读记录', 405);
      _only(query, {'limit'});
      final raw = query['limit']; final requested = raw == null ? 100 : _int(raw is String ? int.tryParse(raw) : raw, -safeInteger, safeInteger);
      final limit = requested < 1 ? 1 : requested > 500 ? 500 : requested;
      final events = state.canonical.where((e) => e['kind'] != 'subscription_charge').toList()
        ..sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
      return (data: [for (final e in events.take(limit)) {'id': e['event_id'], 'kind': e['kind'], 'account_id': e['account_id'],
        'debt_id': e['debt_id'], 'amount': money(e['amount_minor'] as int), 'period': e['period'], 'note': e['note'], 'created_at': e['created_at']}], meta: null);
    }
    _only(query, <String>{});
    if (resource == 'dashboard') {
      if (verb != 'GET') _bad('退休总览只读', 405);
      return (data: await _dashboard(tx, fid, state), meta: null);
    }
    if (resource == 'plan') {
      final entry = await _plan(tx, fid);
      if (verb == 'GET') return (data: _planRead(entry), meta: null);
      if (verb != 'PUT') _bad('此计划不支持该操作', 405);
      _only(body, {'retire_date', 'savings_goal', 'goal_basis', 'surplus_basis', 'client_id'});
      if (body.containsKey('retire_date')) entry['retire_date'] = body['retire_date'] == null ? null : date(day(body['retire_date']));
      if (body.containsKey('savings_goal')) entry['savings_goal_minor'] = body['savings_goal'] == null ? null : minor(body['savings_goal'], nonnegative: true);
      if (body.containsKey('goal_basis')) entry['goal_basis'] = _enum(body['goal_basis'], goalBases);
      if (body.containsKey('surplus_basis')) entry['surplus_basis'] = _enum(body['surplus_basis'], surplusBases);
      entry['updated_by'] = store.deviceId; entry['updated_at'] = now().toUtc().toIso8601String(); entry.remove('id');
      changes.add(change(fid, col(fid, 'retirement', resource), 'family', {'family_id': fid, 'entry': LocalStore.canonical(entry)}));
      return (data: _planRead(entry), meta: null);
    }
    final debt = resource == 'debts';
    if (tail.length == 2 && verb == 'GET') {
      final rows = await _entries(tx, fid, 'retirement', resource);
      rows.sort((a, b) => debt ? (b['created_at'] as String).compareTo(a['created_at'] as String) : (a['created_at'] as String).compareTo(b['created_at'] as String));
      return (data: [for (final row in rows) await _accountRead(tx, fid, row, state, debt: debt)], meta: null);
    }
    if (tail.length == 3 && verb == 'DELETE') {
      await _required(tx, fid, 'retirement', resource, tail[2]); _only(body, {'client_id'});
      changes.add(change(fid, col(fid, 'retirement', resource), tail[2], {}, delete: true));
      return (data: {'deleted': tail[2]}, meta: null);
    }
    if (tail.length == 3 && verb == 'GET') return (data: await _accountRead(tx, fid,
        await _required(tx, fid, 'retirement', resource, tail[2]), state, debt: debt), meta: null);
    final create = tail.length == 2;
    if (create ? verb != 'POST' : verb != 'PUT') _bad('此记录不支持该操作', 405);
    _only(body, {'name', 'kind', 'emoji', 'balance', if (debt) ...['monthly_payment', 'payment_day', 'from_account_id', 'active'] else ...['monthly_income', 'income_day'], 'client_id', 'expected_conflict_frontier'});
    final id = create ? (body['client_id'] == null ? _uuid.v4() : stable('$fid:$resource:${body['client_id']}')) : tail[2];
    final entry = create ? <String, dynamic>{'family_id': fid, 'created_by': store.deviceId,
      'created_at': now().toUtc().toIso8601String(), 'created_on': date(today),
      'basis_event_ids': <String>[], 'acknowledged_conflicts': <String>[], if (!debt) 'settlement_checks': <String, int>{}, if (debt) 'active': true} : await _required(tx, fid, 'retirement', resource, id);
    if (!create && body.containsKey('balance')) {
      final frontier = await _frontier(tx, fid, 'retirement', resource, entry, state);
      if (body['expected_conflict_frontier'] != frontier) _bad('确认期间记录已变化，请重新查看余额与流水后再确认', 409);
    }
    if (create || body.containsKey('name')) entry['name'] = _text(body['name'], 40);
    if (create || body.containsKey('emoji')) entry['emoji'] = _text(body.containsKey('emoji') ? body['emoji'] : (debt ? '🏠' : '🏦'), 16);
    if (create || body.containsKey('kind')) entry['kind'] = _enum(body.containsKey('kind') ? body['kind'] : (debt ? 'mortgage' : 'deposit'), debt ? debtKinds : accountKinds);
    if (create || body.containsKey('balance')) {
      entry['balance_minor'] = minor(body['balance'], nonnegative: debt);
      entry['basis_event_ids'] = state.canonical.where((e) => debt ? e['debt_id'] == id : e['account_id'] == id).map((e) => e['event_id']).toList();
      entry['acknowledged_conflicts'] = state.allConflictKeys(id);
      if (!debt) entry['settlement_checks'] = {for (final event in state.canonical.where((e) => e['kind'] == 'expense_settle'))
        event['event_id'] as String: await _expenseTotal(tx, fid, event['expense_period'] as String)};
    }
    final amountField = debt ? 'monthly_payment' : 'monthly_income', dayField = debt ? 'payment_day' : 'income_day';
    if (create || body.containsKey(amountField)) entry['${amountField}_minor'] = minor(body.containsKey(amountField) ? body[amountField] : 0, nonnegative: true);
    if (create || body.containsKey(dayField)) entry[dayField] = _int(body.containsKey(dayField) ? body[dayField] : 1, 1, 28);
    if (debt) {
      if (create || body.containsKey('from_account_id')) {
        final linked = body['from_account_id'];
        if (linked != null) await _required(tx, fid, 'retirement', 'accounts', _id(linked));
        entry['from_account_id'] = linked;
      }
      if (body.containsKey('active')) entry['active'] = _bool(body['active']);
    }
    entry.remove('id');
    changes.add(change(fid, col(fid, 'retirement', resource), id, {'family_id': fid, 'entry': LocalStore.canonical(entry)}));
    return (data: await _accountRead(tx, fid, {...entry, 'id': id}, state, debt: debt), meta: null);
  }

  String _due(Json entry, _FinancialEvents state) {
    var current = entry['next_due'] as String;
    final charges = {for (final e in state.canonical.where((e) => e['subscription_id'] == entry['id'])) e['due'] as String: e};
    var count = 0;
    while (charges.containsKey(current)) {
      final next = charges[current]!['next_due_after'] as String;
      if (day(next).compareTo(day(current)) <= 0 || ++count > 12000) _bad('订阅到期链无效', 409);
      current = next;
    }
    return current;
  }
  Future<Json> _subscriptionRead(DatabaseExecutor tx, String fid, Json entry, _FinancialEvents state) async {
    final due = _due(entry, state);
    return _author(tx, fid, {...entry, 'amount': money(entry['amount_minor'] as int), 'next_due': due,
      'days_until': day(due).difference(today).inDays,
      'conflict_frontier': await _frontier(tx, fid, 'subscription', 'subscriptions', entry, state), 'billing_conflict': state.subscriptionConflict(entry)});
  }
  Future<LocalResult> _subscription(DatabaseExecutor tx, String verb, String fid, List<String> tail,
      Json body, Json query, _FinancialEvents state, List<Json> changes) async {
    final resource = tail[1];
    if (tail.length == 2 && verb == 'GET') {
      _only(query, {'active'}); final active = StockAccountingRoutes.filterBool(query['active']);
      final rows = <Json>[];
      for (final row in await _entries(tx, fid, 'subscription', resource)) {
        if (active == null || row['active'] == active) rows.add(await _subscriptionRead(tx, fid, row, state));
      }
      rows.sort((a, b) { if (a['active'] != b['active']) return a['active'] == true ? -1 : 1;
        final due = (a['next_due'] as String).compareTo(b['next_due'] as String); return due != 0 ? due : (a['id'] as String).compareTo(b['id'] as String); });
      return (data: rows, meta: null);
    }
    _only(query, <String>{});
    if (tail.length == 3 && verb == 'GET') return (data: await _subscriptionRead(tx, fid, await _required(tx, fid, 'subscription', resource, tail[2]), state), meta: null);
    if (tail.length == 3 && verb == 'DELETE') {
      await _required(tx, fid, 'subscription', resource, tail[2]); _only(body, {'client_id'});
      changes.add(change(fid, col(fid, 'subscription', resource), tail[2], {}, delete: true));
      return (data: {'deleted': tail[2]}, meta: null);
    }
    final create = tail.length == 2;
    if (create ? verb != 'POST' : verb != 'PUT') _bad('此订阅不支持该操作', 405);
    _only(body, {'name', 'emoji', 'amount', 'cycle', 'next_due', 'note', 'notify_enabled', 'notify_days_before', 'auto_record', 'accounting_category', 'exclude_from_budget', 'active', 'client_id', 'confirm_billing', 'expected_conflict_frontier'});
    final id = create ? (body['client_id'] == null ? _uuid.v4() : stable('$fid:subscription:${body['client_id']}')) : tail[2];
    final entry = create ? <String, dynamic>{'family_id': fid, 'created_by': store.deviceId,
      'created_at': now().toUtc().toIso8601String(), 'created_on': date(today),
      'note': null, 'active': true, 'notify_enabled': true, 'notify_days_before': 3,
      'auto_record': true, 'accounting_category': 'subscription', 'exclude_from_budget': false, 'acknowledged_charge_conflicts': <String>[]}
      : await _required(tx, fid, 'subscription', resource, id);
    if (!create && body['confirm_billing'] == true) {
      final frontier = await _frontier(tx, fid, 'subscription', resource, entry, state);
      if (body['expected_conflict_frontier'] != frontier) _bad('确认期间账期或账目已变化，请重新核对后再确认', 409);
    }
    if (create || body.containsKey('name')) entry['name'] = _text(body['name'], 40);
    if (create || body.containsKey('emoji')) entry['emoji'] = _text(body.containsKey('emoji') ? body['emoji'] : '💳', 16);
    if (create || body.containsKey('amount')) { final value = minor(body['amount'], nonnegative: true, subscription: true); if (value <= 0) _bad('订阅金额必须大于0'); entry['amount_minor'] = value; }
    if (create || body.containsKey('cycle')) entry['cycle'] = _enum(body.containsKey('cycle') ? body['cycle'] : 'monthly', {'monthly', 'yearly'});
    if (create || body.containsKey('next_due')) entry['next_due'] = date(day(body['next_due']));
    if (body.containsKey('note')) entry['note'] = StockAccountingRoutes.nullableText(body['note'], 200);
    for (final key in ['active', 'notify_enabled', 'auto_record', 'exclude_from_budget']) { if (body.containsKey(key)) entry[key] = _bool(body[key]); }
    if (body.containsKey('notify_days_before')) entry['notify_days_before'] = _int(body['notify_days_before'], 0, 60);
    if (body.containsKey('accounting_category')) entry['accounting_category'] = _text(body['accounting_category'], 16);
    if (body.containsKey('confirm_billing') && _bool(body['confirm_billing'])) {
      if (!body.containsKey('next_due')) _bad('核对订阅账期后需指定下次到期日');
      entry['acknowledged_charge_conflicts'] = state.subscriptionConflictKeys(id);
    }
    await _category(tx, fid, entry['accounting_category']);
    entry.remove('id'); changes.add(change(fid, col(fid, 'subscription', resource), id, {'family_id': fid, 'entry': LocalStore.canonical(entry)}));
    return (data: await _subscriptionRead(tx, fid, {...entry, 'id': id}, state), meta: null);
  }

  /// Stable review token for exactly the persisted record, all related raw
  /// authenticated occurrences, and current settlement/source expense facts.
  Future<String> _frontier(DatabaseExecutor tx, String fid, String plugin, String resource,
      Json entry, _FinancialEvents state) async {
    final id = entry['id'] as String;
    final eventIds = state.events.where((e) => plugin == 'subscription' ? e['subscription_id'] == id :
      resource == 'debts' ? e['debt_id'] == id : e['account_id'] == id || e['kind'] == 'expense_settle' && e['account_id'] == null)
      .map((e) => e['event_id']).toSet();
    final related = state.events.where((e) => eventIds.contains(e['event_id'])).toList();
    final encodedEvents = related.map((e) => LocalStore.canonical({
      for (final key in {...eventSemanticFields, 'event_id', 'actor', 'order', 'created_at'}) if (e.containsKey(key)) key: e[key],
      'source_sequence': e['_source_sequence'],
    })).toSet().toList()..sort();
    final totals = <String, int>{};
    final index = <Json>[];
    final expenses = <Json>[];
    if (plugin == 'retirement' && resource == 'accounts') {
      final periods = related.where((e) => e['kind'] == 'expense_settle').map((e) => e['expense_period'] as String).toSet().toList()..sort();
      for (final month in periods) { totals[month] = await _expenseTotal(tx, fid, month); }
      for (final account in await _entries(tx, fid, 'retirement', 'accounts')) {
        index.add({'id': account['id'], 'kind': account['id'] == id ? entry['kind'] : account['kind'], 'created_at': account['id'] == id ? entry['created_at'] : account['created_at']});
      }
      if (!index.any((row) => row['id'] == id)) index.add({'id': id, 'kind': entry['kind'], 'created_at': entry['created_at']});
      index.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    }
    if (plugin == 'subscription') {
      for (final expense in await _entries(tx, fid, 'accounting', 'transactions')) {
        if (expense['source_plugin'] == 'subscription' && expense['source_id'] == id) expenses.add(expense);
      }
      expenses.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    }
    final facts = {'schema': 1, 'family_id': fid, 'plugin': plugin, 'resource': resource, 'record_id': id,
      'entry': {...entry}..remove('id'), 'events': [for (final encoded in encodedEvents) jsonDecode(encoded)],
      'settlement_totals': totals, 'account_index': index, 'expenses': expenses};
    return stable('wo-finance-frontier-v1:${LocalStore.canonical(facts)}');
  }

  Future<int> _expenseTotal(DatabaseExecutor tx, String fid, String month) async {
    var total = 0;
    for (final entry in await _entries(tx, fid, 'accounting', 'transactions')) {
      if ((entry['calendar_date'] as String).startsWith('$month-')) total = sum(total, entry['amount_minor'] as int);
    }
    return total;
  }
  Future<bool> _settlementConflict(DatabaseExecutor tx, String fid, Json account, _FinancialEvents state) async {
    if (account['kind'] != 'deposit') return false;
    final checks = account['settlement_checks'] as Map? ?? {};
    final known = await _entries(tx, fid, 'retirement', 'accounts');
    final deposits = [for (final row in known) if (row['id'] != account['id']) row, account].where((a) => a['kind'] == 'deposit').toList()
      ..sort((a, b) { final t = (a['created_at'] as String).compareTo(b['created_at'] as String); return t != 0 ? t : (a['id'] as String).compareTo(b['id'] as String); });
    for (final event in state.canonical.where((e) => e['kind'] == 'expense_settle')) {
      final target = event['account_id'] ?? (deposits.isEmpty ? null : deposits.first['id']);
      if (target != account['id']) continue;
      final current = await _expenseTotal(tx, fid, event['expense_period'] as String);
      if (current != event['amount_minor'] && checks[event['event_id']] != current) return true;
    }
    return false;
  }

  Future<Json> _dashboard(DatabaseExecutor tx, String fid, _FinancialEvents state) async {
    final asOf = today;
    final accounts = await _entries(tx, fid, 'retirement', 'accounts');
    final debts = await _entries(tx, fid, 'retirement', 'debts');
    var deposit = 0, fund = 0, debt = 0, income = 0, payments = 0;
    var ledgerConflict = false;
    for (final account in accounts) {
      final balance = state.balance(account);
      if (account['kind'] == 'deposit') deposit = sum(deposit, balance); else fund = sum(fund, balance);
      income = sum(income, account['monthly_income_minor'] as int);
      if (state.conflicts(account).isNotEmpty || await _settlementConflict(tx, fid, account, state)) ledgerConflict = true;
    }
    for (final row in debts) {
      final balance = state.balance(row, debt: true);
      if (state.conflicts(row).isNotEmpty || balance < 0) ledgerConflict = true;
      if (row['active'] == true && balance > 0) { debt = sum(debt, balance); payments = sum(payments, row['monthly_payment_minor'] as int); }
    }
    final assets = sum(deposit, fund), worth = sum(assets, -debt);
    final plan = await _plan(tx, fid);
    final basis = plan['goal_basis'] as String, surplusBasis = plan['surplus_basis'] as String;
    final current = basis == 'total_assets' ? assets : basis == 'deposit_only' ? deposit : worth;
    var expense = 0;
    if (surplusBasis == 'income_debt_expense') {
      expense = await _expenseTotal(tx, fid, previousPeriod(asOf));
      if (expense <= 0) {
        final row = await _doc(tx, fid, col(fid, 'accounting', 'budget'), 'monthly');
        expense = row == null ? 0 : _entry(row)['monthly_amount_minor'] as int;
      }
    }
    final surplus = surplusBasis == 'income_only' ? income : surplusBasis == 'income_debt' ? sum(income, -payments) : sum(sum(income, -payments), -expense);
    final retireDate = plan['retire_date'] as String?;
    final goal = plan['savings_goal_minor'] as int?;
    final months = retireDate == null ? null : (day(retireDate).year - asOf.year) * 12 + day(retireDate).month - asOf.month;
    final monthsLeft = months == null ? null : months < 0 ? 0 : months;
    final remaining = goal == null ? null : sum(goal, -current);
    final reached = goal != null && current >= goal;
    final monthsToGoal = goal == null ? null : reached ? 0 : surplus <= 0 ? null : ceilDivide(remaining!, surplus);
    final required = remaining == null || monthsLeft == null || monthsLeft <= 0 ? null : halfEvenDivide(remaining < 0 ? 0 : remaining, monthsLeft);
    return {'total_deposit': money(deposit), 'total_fund': money(fund), 'total_assets': money(assets),
      'total_debt': money(debt), 'net_worth': money(worth), 'current': money(current),
      'monthly_income': money(income), 'monthly_debt': money(payments), 'monthly_expense': money(expense),
      'monthly_surplus': money(surplus), ..._planRead(plan),
      'days_to_retire': retireDate == null ? null : day(retireDate).difference(asOf).inDays,
      'months_to_retire': monthsLeft, 'goal_reached': reached,
      'remaining': remaining == null ? null : money(remaining), 'months_to_goal': monthsToGoal,
      'required_monthly': required == null ? null : money(required),
      'monthly_gap': required == null ? null : money(sum(surplus, -required)),
      'accounting_installed': await _installed(tx, fid, 'accounting'), 'ledger_conflict': ledgerConflict};
  }

  /// One foreground pass matching the original server pass: current retirement
  /// month and one subscription cycle. Repeated passes are idempotent.
  Future<int> processDue(String fid) async {
    final asOf = today;
    late List<String> accounts, debts, subscriptions;
    var enabled = false;
    await store.batchComputed((tx) async {
      await _member(tx, fid);
      enabled = await _installed(tx, fid, 'retirement', enabled: true);
      accounts = [for (final row in await _rows(tx, fid, col(fid, 'retirement', 'accounts'))) row['id'] as String];
      debts = [for (final row in await _rows(tx, fid, col(fid, 'retirement', 'debts'))) row['id'] as String];
      subscriptions = [for (final row in await _rows(tx, fid, col(fid, 'subscription', 'subscriptions'))) row['id'] as String];
      return <Json>[];
    });
    var count = 0;
    if (enabled) {
      for (final id in accounts) { count += await _retireDue(fid, 'income', id, asOf); }
      for (final id in debts) { count += await _retireDue(fid, 'debt_payment', id, asOf); }
      count += await _retireDue(fid, 'expense_settle', 'family', asOf);
    }
    for (final id in subscriptions) { count += await _subscriptionDue(fid, id, asOf); }
    return count;
  }

  Future<Json> _appendEvent(DatabaseExecutor tx, String fid, String plugin, String resource,
      String id, Json payload, List<Json> changes) async {
    final clocks = await tx.query('meta', where: 'key=?', whereArgs: ['clock:$fid']);
    final clock = clocks.isEmpty ? 0 : jsonDecode(clocks.single['value'] as String) as int;
    final event = {...payload, 'event_id': id, 'actor': store.deviceId, 'order': clock + changes.length + 1,
      'created_at': now().toUtc().toIso8601String()};
    changes.add(change(fid, col(fid, plugin, resource), id, {'event': LocalStore.canonical(event)}));
    return event;
  }
  Future<bool> _notify(DatabaseExecutor tx, String fid, String id, String plugin,
      String sourceId, String type, String title, String body, String emoji, List<Json> changes) async {
    final collection = '/families/$fid/notifications';
    if (await _doc(tx, fid, collection, id) != null) return false;
    final members = await _rows(tx, fid, '/families/$fid/members');
    changes.add(change(fid, collection, id, {'type': type, 'title': title, 'body': body,
      'icon_emoji': emoji, 'created_by': store.deviceId, 'created_at': now().toUtc().toIso8601String(),
      'read_by': <String>[], 'status': 'pending_local_delivery',
      'recipient_ids': [for (final member in members) if (member['status'] == 'active') member['user_id']],
      'source_plugin': plugin, 'source_id': sourceId}));
    return true;
  }
  Future<int> _retireDue(String fid, String kind, String sourceId, DateTime asOf) async {
    final today = asOf;
    var touched = 0;
    await store.batchComputed((tx) async {
      await _member(tx, fid);
      if (!await _installed(tx, fid, 'retirement', enabled: true)) return <Json>[];
      final month = period(today);
      final monthStart = DateTime.utc(today.year, today.month, 1);
      final id = stable('retirement:$fid:$kind:$month:$sourceId');
      final state = await _FinancialEvents.load(tx, fid);
      if (state.canonical.any((e) => e['event_id'] == id)) return <Json>[];
      final changes = <Json>[];
      String? accountId, debtId;
      var amount = 0;
      String note;
      if (kind == 'income') {
        final raw = await _doc(tx, fid, col(fid, 'retirement', 'accounts'), sourceId);
        if (raw == null) return changes;
        final account = _entry(raw);
        final created = day(account['created_on']);
        if (created.isAfter(today) || today.day < (account['income_day'] as int) ||
            created.compareTo(monthStart) >= 0 && created.day > (account['income_day'] as int)) return changes;
        if (state.conflicts(account).isNotEmpty) _bad('收入账户存在待核对账本冲突', 409);
        amount = account['monthly_income_minor'] as int;
        if (amount <= 0) return changes;
        accountId = sourceId; note = '${account['name']} 月收入入账';
      } else if (kind == 'debt_payment') {
        final raw = await _doc(tx, fid, col(fid, 'retirement', 'debts'), sourceId);
        if (raw == null) return changes;
        final debt = _entry(raw);
        final balance = state.balance(debt, debt: true);
        if (balance < 0 || state.conflicts(debt).isNotEmpty) _bad('负债余额存在待核对冲突', 409);
        if (debt['active'] != true || day(debt['created_on']).isAfter(today) || balance <= 0 || today.day < (debt['payment_day'] as int)) return changes;
        final payment = debt['monthly_payment_minor'] as int;
        amount = payment < balance ? payment : balance;
        if (amount <= 0) return changes;
        debtId = sourceId;
        final linked = debt['from_account_id'];
        final account = linked is String ? await _doc(tx, fid, col(fid, 'retirement', 'accounts'), linked) : null;
        if (account != null) {
          if (state.conflicts(_entry(account)).isNotEmpty) _bad('还款账户存在待核对冲突', 409);
          accountId = linked as String;
        }
        note = '${debt['name']} 月供扣款';
      } else {
        final accounts = await _entries(tx, fid, 'retirement', 'accounts');
        if (!accounts.any((a) => day(a['created_on']).isBefore(monthStart))) return changes;
        accounts.sort((a, b) { final created = (a['created_at'] as String).compareTo(b['created_at'] as String); return created != 0 ? created : (a['id'] as String).compareTo(b['id'] as String); });
        amount = await _expenseTotal(tx, fid, previousPeriod(today));
        final deposits = accounts.where((a) => a['kind'] == 'deposit').toList();
        if (amount > 0 && deposits.isNotEmpty) {
          final account = deposits.first;
          if (state.conflicts(account).isNotEmpty) _bad('支出结算账户存在待核对冲突', 409);
          accountId = account['id'] as String;
        }
        note = accountId != null ? '结算 ${previousPeriod(today)} 记账支出' : amount <= 0 ? '${previousPeriod(today)} 无记账支出' : '无存款账户可扣';
      }
      await _appendEvent(tx, fid, 'retirement', 'ledger', id, {'kind': kind, 'account_id': accountId,
        'debt_id': debtId, 'amount_minor': amount, 'period': month,
        if (kind == 'expense_settle') 'expense_period': previousPeriod(today), 'note': note}, changes);
      if (kind == 'debt_payment' || kind == 'expense_settle' && accountId != null) {
        await _notify(tx, fid, stable('notice:$id'), 'retirement', sourceId, kind == 'debt_payment' ? 'retirement_debt_charged' : 'retirement_expense_settled',
          kind == 'debt_payment' ? '已记录本期还款 ${money(amount)}' : '已结算上月支出 ${money(amount)}',
          '本机账本已更新；系统提醒等待本地投递', kind == 'debt_payment' ? '🏠' : '🧮', changes);
      }
      touched = 1;
      return changes;
    });
    return touched;
  }

  Future<int> _subscriptionDue(String fid, String sourceId, DateTime asOf) async {
    final today = asOf;
    var touched = 0;
    await store.batchComputed((tx) async {
      await _member(tx, fid);
      final raw = await _doc(tx, fid, col(fid, 'subscription', 'subscriptions'), sourceId);
      if (raw == null) return <Json>[];
      final entry = _entry(raw);
      if (entry['active'] != true) return <Json>[];
      final state = await _FinancialEvents.load(tx, fid);
      if (state.subscriptionConflict(entry)) _bad('订阅账期事件存在待核对冲突，未继续记账', 409);
      final due = _due(entry, state);
      final delta = day(due).difference(today).inDays;
      final changes = <Json>[];
      if (delta > 0) {
        if (entry['notify_enabled'] == true && delta <= (entry['notify_days_before'] as int)) {
          touched = await _notify(tx, fid, stable('subscription-due:$fid:$sourceId:$due'), 'subscription', sourceId,
            'subscription_due', '「${entry['name']}」$delta 天后到期 ${money(entry['amount_minor'] as int)}',
            '提前检查续费设置；系统提醒等待本地投递', entry['emoji'] as String, changes) ? 1 : 0;
        }
        return changes;
      }
      final id = stable('subscription-charge:$fid:$sourceId:$due');
      final recorded = entry['auto_record'] == true && await _installed(tx, fid, 'accounting');
      if (recorded) await _category(tx, fid, entry['accounting_category']);
      await _appendEvent(tx, fid, 'subscription', 'charges', id, {'kind': 'subscription_charge',
        'subscription_id': sourceId, 'amount_minor': entry['amount_minor'], 'due': due,
        'period': due.substring(0, 7), 'next_due_after': advanceDue(due, entry['cycle'] as String),
        'auto_recorded': recorded, 'accounting_category': entry['accounting_category'],
        'exclude_from_budget': entry['exclude_from_budget'], 'note': '${entry['name']} 订阅到期'}, changes);
      if (recorded) {
        final expense = {'family_id': fid, 'created_by': store.deviceId, 'created_at': now().toUtc().toIso8601String(),
          'calendar_date': due, 'calendar_offset_minutes': now().toLocal().timeZoneOffset.inMinutes,
          'amount_minor': entry['amount_minor'], 'category': entry['accounting_category'],
          'note': '${entry['name']} 订阅扣费', 'exclude_from_budget': entry['exclude_from_budget'],
          'source_plugin': 'subscription', 'source_id': sourceId, 'source_occurrence': due, 'source_event_id': id};
        changes.add(change(fid, col(fid, 'accounting', 'transactions'), stable('subscription-expense:$fid:$sourceId:$due'),
          {'family_id': fid, 'entry': LocalStore.canonical(expense)}));
      }
      await _notify(tx, fid, stable('notice:$id'), 'subscription', sourceId, 'subscription_charged',
        recorded ? '「${entry['name']}」到期已自动记账 ${money(entry['amount_minor'] as int)}' : '「${entry['name']}」到期 ${money(entry['amount_minor'] as int)}',
        recorded ? '已按设置写入本机记账；系统提醒等待本地投递' : '请核对是否续费；系统提醒等待本地投递', entry['emoji'] as String, changes);
      touched = 1;
      return changes;
    });
    return touched;
  }
}

class _FinancialEvents {
  _FinancialEvents(this.events);
  final List<Json> events;
  static String semantic(Json value) => RetirementSubscriptionRoutes.eventSemantic(value);
  static Future<_FinancialEvents> load(DatabaseExecutor tx, String fid) async {
    final rows = await tx.query('operations', columns: ['payload'], where: 'space=?', whereArgs: [fid]);
    final events = <Json>[];
    for (final row in rows) {
      final operation = Json.from(jsonDecode(row['payload'] as String) as Map);
      final retirement = operation['collection'] == '/families/$fid/plugins/retirement/ledger';
      final subscription = operation['collection'] == '/families/$fid/plugins/subscription/charges';
      if (!retirement && !subscription) continue;
      final fields = operation['fields'];
      if (operation['kind'] != 'patch' || fields is! Map || fields.length != 1 || fields['event'] is! String) RetirementSubscriptionRoutes._bad('财务事件不可删除或修改结构', 409);
      try {
        events.add({...RetirementSubscriptionRoutes.decodeEvent(fields['event'], expectedId: operation['id'] as String,
          actor: operation['actor'] as String, order: operation['clock'] as int, subscription: subscription), '_source_sequence': operation['sequence']});
      } on FormatException { RetirementSubscriptionRoutes._bad('财务事件来源、金额或账期无效', 409); }

    }
    return _FinancialEvents(events);
  }
  List<Json> get canonical {
    final sorted = [...events]..sort((a, b) {
      final order = (a['order'] as int).compareTo(b['order'] as int);
      final actor = (a['actor'] as String).compareTo(b['actor'] as String);
      return order != 0 ? order : actor != 0 ? actor : (a['event_id'] as String).compareTo(b['event_id'] as String);
    });
    return {for (final event in sorted) event['event_id'] as String: event}.values.toList();
  }
  int balance(Json entry, {bool debt = false}) {
    final id = entry['id'];
    final basis = ((entry['basis_event_ids'] as List?) ?? []).cast<String>().toSet();
    var balance = entry['balance_minor'] as int;
    for (final event in canonical) {
      if (basis.contains(event['event_id']) || (debt ? event['debt_id'] != id : event['account_id'] != id)) continue;
      final amount = event['amount_minor'] as int;
      balance = RetirementSubscriptionRoutes.sum(balance, debt || event['kind'] != 'income' ? -amount : amount);
    }
    return balance;
  }
  List<String> allConflictKeys(String id) {
    final relevant = events.where((e) => e['account_id'] == id || e['debt_id'] == id).map((e) => e['event_id']).toSet();
    final grouped = <String, Set<String>>{};
    for (final e in events) if (relevant.contains(e['event_id'])) grouped.putIfAbsent(e['event_id'] as String, () => <String>{}).add(semantic(e));
    return [for (final group in grouped.entries) if (group.value.length > 1) for (final variant in group.value) '${group.key}:$variant']..sort();
  }
  List<String> conflicts(Json entry) {
    final acknowledged = ((entry['acknowledged_conflicts'] as List?) ?? []).cast<String>().toSet();
    return allConflictKeys(entry['id'] as String).where((key) => !acknowledged.contains(key)).toList();
  }
  List<String> subscriptionConflictKeys(String id) {
    final grouped = <String, Set<String>>{};
    for (final e in events.where((e) => e['subscription_id'] == id)) grouped.putIfAbsent(e['event_id'] as String, () => <String>{}).add(semantic(e));
    return [for (final group in grouped.entries) if (group.value.length > 1) for (final variant in group.value) '${group.key}:$variant']..sort();
  }
  bool subscriptionConflict(Json entry) {
    final acknowledged = ((entry['acknowledged_charge_conflicts'] as List?) ?? []).cast<String>().toSet();
    return subscriptionConflictKeys(entry['id'] as String).any((key) => !acknowledged.contains(key));
  }
}
