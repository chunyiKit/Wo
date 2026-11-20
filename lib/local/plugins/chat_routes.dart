import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../local_backend.dart';
import '../attachments/attachment_descriptor.dart';
import '../attachments/ordinary_attachment_store.dart';
import '../local_store.dart';

/// 消息事实存放本地 SQLite；局域网增量由独立同步策略驱动。
/// created_at 只用于阅读排序，绝不作为同步游标。
class ChatRoutes {
  ChatRoutes(this.store, {this.attachments, this.attachmentStore, DateTime Function()? now}) : now = now ?? DateTime.now;
  final LocalStore store;
  final OrdinaryAttachmentStore? attachments;
  final Future<OrdinaryAttachmentStore> Function()? attachmentStore;
  Future<OrdinaryAttachmentStore?> _repository() async {
    if (attachments != null) return attachments;
    final provider = attachmentStore;
    return provider == null ? null : await provider();
  }
  final DateTime Function() now;
  static const uuid = Uuid();
  static final _commits = <(String, String, String), Future<Json>>{};
  static const maxPending = 100;
  static const namespace = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';
  static const syncFields = <String, Set<String>>{
    'plugins/chat/messages': {'family_id', 'created_by', 'client_id', 'kind', 'body', 'created_at', 'attachment_id'},
    'plugins/chat/attachments': AttachmentDescriptor.syncFields,
    'plugins/chat/status': {'family_id', 'created_by', 'emoji', 'text', 'updated_at'},
  };
  static final _ids = RegExp(r'^[A-Za-z0-9_-]{1,100}$');
  static bool _id(Object? value, [int max = 100]) {
    if (value is! String || value.length > max) return false;
    final match = _ids.firstMatch(value);
    return match != null && match.start == 0 && match.end == value.length;
  }
  static String messageId(String fid, String actor, String client) =>
    uuid.v5(namespace, 'wo-chat-v1:$fid:$actor:$client');
  static String attachmentId(String fid, String actor, String client) =>
    'a_${uuid.v5(namespace, 'wo-chat-attachment-v1:$fid:$actor:$client').replaceAll('-', '')}';
  AttachmentBinding attachmentBinding(String fid, String parent, String author) =>
    AttachmentBinding(familyId: fid, plugin: 'chat', parentId: parent, authorDeviceId: author);
  String col(String fid, String name) => '/families/$fid/plugins/chat/$name';
  static Never _fail(int status, String message) => throw ApiException(
    switch (status) {403=>'FORBIDDEN',404=>'NOT_FOUND',405=>'METHOD_NOT_ALLOWED',409=>'CONFLICT',501=>'FEATURE_UNAVAILABLE',_=>'VALIDATION_ERROR'},
    message, statusCode: status);
  static void _only(Json value, Set<String> keys) {
    if (value.keys.any((key) => !keys.contains(key))) _fail(400, '包含未知或只读字段');
  }
  static String _text(Object? value, int max, {bool empty = false}) {
    if (value is! String || value.runes.length > max || (!empty && value.trim().isEmpty)) _fail(400, '文字为空或超过长度限制');
    return value.trim();
  }
  static Future<Json?> _document(DatabaseExecutor tx, String fid, String collection, String id,
    {bool includeDeleted = false}) async {
    final rows = await tx.query('documents', where: 'space=? AND collection=? AND id=?${includeDeleted ? '' : ' AND deleted=0'}', whereArgs: [fid, collection, id]);
    if (rows.isEmpty) return null;
    return {...Json.from(jsonDecode(rows.single['data'] as String) as Map),
      'id': id, if (includeDeleted) 'retracted': rows.single['deleted'] == 1};
  }
  Future<Json> _member(DatabaseExecutor tx, String fid, [String? user]) async {
    if (!_id(fid) || !_id(user ?? store.deviceId)) _fail(400, '家庭或成员标识无效');
    final actor = user ?? store.deviceId;
    final member = await _document(tx, fid, '/families/$fid/members', actor);
    if (member == null || member['status'] != 'active' || member['family_id'] != fid || member['user_id'] != actor) _fail(403, '本机没有有效家庭成员权限');
    return member;
  }
  Future<Json> _read(DatabaseExecutor tx, String fid, Json row) async {
    final actor = row['created_by'];
    if (!_id(actor) || !_id(row['client_id'], 80) || !{'text', 'image', 'file'}.contains(row['kind']) || row['family_id'] != fid ||
        row['id'] != messageId(fid, actor as String, row['client_id'] as String) ||
        row['body'] is! String || row['created_at'] is! String || DateTime.tryParse(row['created_at'] as String) == null) {
      _fail(409, '本地聊天记录需要核对，未展示不完整内容');
    }
    final kind = row['kind'] as String;
    Json? attachment;
    if (kind != 'text') {
      if (row['attachment_id'] != attachmentId(fid, actor, row['client_id'] as String) || row['body'] != '') _fail(409, '附件消息标识需要核对');
      if (row['retracted'] != true) {
        final raw = await _document(tx, fid, col(fid, 'attachments'), row['attachment_id'] as String);
        // 元数据可能分包到达；缺件仍保留稳定消息行，绝不误报字节送达。
        if (raw != null) {
          final descriptor = _descriptor(fid, row['id'] as String, actor, raw);
          if (descriptor.kind != kind) _fail(409, '附件类型与消息不一致');
          attachment = descriptor.toJson();
        }
      }
    } else if (row.containsKey('attachment_id')) { _fail(409, '文字消息包含非预期附件'); }
    final member = await _document(tx, fid, '/families/$fid/members', actor);
    final active = member != null && member['status'] == 'active' && member['user_id'] == actor && member['family_id'] == fid;
    final retracted = row['retracted'] == true;
    return {'id': row['id'], 'family_id': fid, 'sender_id': active ? actor : null,
      'client_id': row['client_id'], 'kind': kind, 'attachment': retracted ? null : attachment, 'attachment_status': kind == 'text' ? null : 'missing_local', 'body': retracted ? null : row['body'],
      'created_at': row['created_at'], 'sender_name': active ? member['display_name'] : '已离开的家人',
      'sender_emoji': active ? member['avatar_emoji'] : '👤', 'sender_avatar_url': active ? member['avatar_url'] : null,
      'image': null, 'retracted': retracted, 'local_pending': false, 'delivery_status': 'saved_local'};
  }
  AttachmentDescriptor _descriptor(String fid, String parent, String actor, Json raw) {
    final descriptor = AttachmentDescriptor.fromJson(raw);
    if (descriptor.familyId != fid || descriptor.plugin != 'chat' || descriptor.parentId != parent ||
        descriptor.authorDeviceId != actor || !{'chat_image_copy', 'chat_file_copy'}.contains(descriptor.purpose)) {
      _fail(409, '附件归属需要核对');
    }
    return descriptor;
  }
  Future<AttachmentDescriptor> _readableAttachment(DatabaseExecutor tx, String fid, String message) async {
    await _member(tx, fid);
    final row = await _document(tx, fid, col(fid, 'messages'), message);
    if (row == null || row['kind'] == 'text') _fail(404, '附件消息不存在或已撤回');
    final projection = await _read(tx, fid, row);
    final raw = projection['attachment'];
    if (raw is! Map) _fail(404, '附件元数据尚未到达');
    return _descriptor(fid, message, row['created_by'] as String, Json.from(raw));
  }
  /// 每次访问字节都重查当前成员、消息和descriptor，不以缓存文件存在替代授权。
  Future<File?> attachmentFile(String fid, String message) async {
    final repository = await _repository();
    if (repository == null) return null;
    final descriptor = await store.db.transaction((tx) => _readableAttachment(tx, fid, message));
    if (descriptor.kind != 'image') return null;
    final file = await repository.verifiedFile(attachmentBinding(fid, message, descriptor.authorDeviceId), descriptor.id);
    final current = await store.db.transaction((tx) => _readableAttachment(tx, fid, message));
    if (LocalStore.canonical(current.toJson()) != LocalStore.canonical(descriptor.toJson())) _fail(409, '附件已变化');
    return file;
  }
  Future<List<Json>> _attachmentStates(String fid, List<Json> rows) async {
    if (!rows.any((row) => row['retracted'] != true && row['attachment'] is Map)) return rows;
    OrdinaryAttachmentStore? repository;
    try { repository = await _repository(); } catch (_) { /*本机副本不可用不隐藏已保存的聊天元数据。*/ }
    if (repository == null) {
      await store.db.transaction((tx) => _member(tx, fid));
      return rows;
    }
    for (final row in rows) {
      if (row['retracted'] == true || row['attachment'] is! Map) continue;
      final descriptor = AttachmentDescriptor.fromJson(Json.from(row['attachment'] as Map));
      try {
        final binding = attachmentBinding(fid, row['id'] as String, descriptor.authorDeviceId);
        final asset = await repository.get(binding, descriptor.id);
        if (asset?.available == true && asset!.descriptor.same(descriptor)) {
          await repository.verifiedFile(binding, descriptor.id);
          row['attachment_status'] = 'available_local';
        } else { row['attachment_status'] = 'missing_local'; }
      } catch (_) { row['attachment_status'] = 'missing_local'; }
    }
    // 欠缺字节状态只反映本机，不代表任一其他设备已接收。
    await store.db.transaction((tx) async {
      await _member(tx, fid);
      for (var i = 0; i < rows.length; i++) {
        if (rows[i]['local_pending'] == true) continue;
        final live = await _document(tx, fid, col(fid, 'messages'), rows[i]['id'] as String, includeDeleted: true);
        if (live == null || live['retracted'] == true) {
          rows[i] = live == null ? {...rows[i], 'body': null, 'attachment': null, 'attachment_status': null, 'retracted': true} : await _read(tx, fid, live);
        }
      }
    });
    return rows;
  }
  Future<List<Json>> _snapshot(DatabaseExecutor tx, String fid) async {
    await _member(tx, fid);
    final rows = await tx.query('documents', where: 'space=? AND collection=?', whereArgs: [fid, col(fid, 'messages')]);
    final result = <Json>[];
    for (final row in rows) {
      final values = {...Json.from(jsonDecode(row['data'] as String) as Map), 'id': row['id'], 'retracted': row['deleted'] == 1};
      result.add(await _read(tx, fid, values));
    }
    result.sort(compareMessages);
    return result;
  }
  static int compareMessages(Json a, Json b) {
    final order = DateTime.parse(a['created_at'] as String).compareTo(DateTime.parse(b['created_at'] as String));
    return order != 0 ? order : (a['id'] as String).compareTo(b['id'] as String);
  }
  /// 每次读事实源快照，因此早时间补录、撤回和已有行变化都不依赖时间游标。
  Future<List<Json>> snapshot(String fid) => store.db.transaction((tx) => _snapshot(tx, fid));

  String _outboxKey(String fid) => 'private:chat-outbox:$fid:${store.deviceId}';
  Future<List<Json>> _outbox(DatabaseExecutor tx, String fid) async {
    final rows = await tx.query('meta', where: 'key=?', whereArgs: [_outboxKey(fid)]);
    if (rows.isEmpty) return [];
    final value = jsonDecode(rows.single['value'] as String);
    if (value is! List || value.length > maxPending) _fail(409, '本机待发送草稿需要核对');
    final result = <Json>[], seen = <String>{};
    for (final raw in value) {
      if (raw is! Map) _fail(409, '本机待发送草稿需要核对');
      final draft = Json.from(raw);
      final attachmentDraft = draft['kind'] == 'image' || draft['kind'] == 'file';
      final keys = attachmentDraft ? {'client_id', 'body', 'created_at', 'kind', 'attachment'} : {'client_id', 'body', 'created_at'};
      if (draft.length != keys.length || !draft.keys.toSet().containsAll(keys) ||
          !_id(draft['client_id'], 80) || draft['body'] is! String ||
          (draft['body'] as String).runes.length > 2000 || (!attachmentDraft && (draft['body'] as String).trim().isEmpty) ||
          draft['created_at'] is! String || !(draft['created_at'] as String).endsWith('Z') ||
          DateTime.tryParse(draft['created_at'] as String) == null || !seen.add(draft['client_id'] as String)) {
        _fail(409, '本机待发送草稿需要核对');
      }
      if (attachmentDraft) {
        if (draft['attachment'] is! Map || draft['body'] != '') _fail(409, '附件草稿需要核对');
        final descriptor = _descriptor(fid, messageId(fid, store.deviceId, draft['client_id'] as String), store.deviceId, Json.from(draft['attachment'] as Map));
        if (descriptor.id != attachmentId(fid, store.deviceId, draft['client_id'] as String) || descriptor.kind != draft['kind']) _fail(409, '附件草稿标识需要核对');
      }
      result.add(draft);
    }
    return result;
  }
  Future<void> _saveOutbox(DatabaseExecutor tx, String fid, List<Json> values) async {
    if (values.isEmpty) { await tx.delete('meta', where: 'key=?', whereArgs: [_outboxKey(fid)]); return; }
    await tx.insert('meta', {'key': _outboxKey(fid), 'value': LocalStore.canonical(values)}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  Future<void> _checkDraftReceipt(DatabaseExecutor tx, String fid, Json draft, Json receipt) async {
    final kind = draft['kind'] ?? 'text';
    if (receipt['created_by'] != store.deviceId || receipt['client_id'] != draft['client_id'] ||
        receipt['kind'] != kind || receipt['body'] != draft['body']) _fail(409, '待发送草稿与本机回执冲突');
    if (kind != 'text') {
      final descriptor = _descriptor(fid, receipt['id'] as String, store.deviceId, Json.from(draft['attachment'] as Map));
      if (receipt['attachment_id'] != descriptor.id) _fail(409, '附件回执标识冲突');
      final saved = await _document(tx, fid, col(fid, 'attachments'), descriptor.id, includeDeleted: true);
      if (saved == null) _fail(409, '附件回执元数据缺失');
      final fields = Json.from(saved)..remove('retracted');
      if (!_descriptor(fid, receipt['id'] as String, store.deviceId, fields).same(descriptor)) _fail(409, '附件回执内容冲突');
    }
  }
  Future<void> _ackPending(DatabaseExecutor tx, String fid, String client, String body) async {
    final pending = await _outbox(tx, fid);
    final old = pending.where((row) => row['client_id'] == client).firstOrNull;
    if (old == null) return;
    if (old['body'] != body) _fail(409, '同一草稿标识对应不同正文');
    pending.removeWhere((row) => row['client_id'] == client);
    await _saveOutbox(tx, fid, pending);
  }
  /// 私有草稿先单独落盘；不进documents、operations或手机间同步。
  Future<Json> stageText(String fid, {required String clientId, required String body}) async {
    if (!_id(clientId, 80)) _fail(400, 'client_id 无效');
    final text = _text(body, 2000);
    return store.db.transaction((tx) async {
      await _member(tx, fid);
      final id = messageId(fid, store.deviceId, clientId);
      final existing = await _document(tx, fid, col(fid, 'messages'), id, includeDeleted: true);
      if (existing != null) {
        if (existing['kind'] != 'text' || existing['body'] != text || existing['client_id'] != clientId || existing['created_by'] != store.deviceId) _fail(409, '同一草稿标识对应不同正文');
        await _ackPending(tx, fid, clientId, text);
        return _read(tx, fid, existing);
      }
      final pending = await _outbox(tx, fid);
      final old = pending.where((row) => row['client_id'] == clientId).firstOrNull;
      if (old != null) {
        if (old['body'] != text || old.containsKey('attachment')) _fail(409, '同一草稿标识对应不同正文');
        return {...old, 'id': id};
      }
      if (pending.length >= maxPending) _fail(409, '本机待发送草稿已达100条，请先重试或删除已有草稿');
      final draft = {'client_id': clientId, 'body': text, 'created_at': now().toUtc().toIso8601String()};
      pending.add(draft); await _saveOutbox(tx, fid, pending);
      return {...draft, 'id': id};
    });
  }
  /// 原生picker只生成受控聊天副本，取消/授权失效时释放一次性选择，不读取回忆源引用。
  Future<Json?> selectAttachment(String fid, {required String clientId, required String purpose,
    required Future<bool> Function(AttachmentSelectionMetadata selection) confirm}) async {
    if (!{'chat_image_copy', 'chat_file_copy'}.contains(purpose) || !_id(clientId, 80)) _fail(400, '附件用途无效');
    await store.db.transaction((tx) => _member(tx, fid));
    final repository = await _repository();
    if (repository == null) _fail(501, '本机附件选择尚未就绪');
    final selected = await repository.pick(purpose: purpose);
    if (selected == null) return null;
    try {
      if (!await confirm(selected)) return null;
      await store.db.transaction((tx) => _member(tx, fid));
      final id = messageId(fid, store.deviceId, clientId);
      final asset = await repository.importSelection(selectionToken: selected.token, purpose: purpose,
        binding: attachmentBinding(fid, id, store.deviceId), attachmentId: attachmentId(fid, store.deviceId, clientId));
      return await stageAttachment(fid, clientId: clientId, descriptor: asset.descriptor);
    } finally { try { await repository.releaseSelection(selected.token); } catch (_) {} }
  }
  /// 仅接收已冻结到本机私有目录的副本描述；原URI、选择token和回忆原件引用不入草稿或操作日志。
  Future<Json> stageAttachment(String fid, {required String clientId, required AttachmentDescriptor descriptor}) async {
    if (!_id(clientId, 80)) _fail(400, 'client_id 无效');
    final id = messageId(fid, store.deviceId, clientId);
    final value = _descriptor(fid, id, store.deviceId, descriptor.toJson());
    if (value.id != attachmentId(fid, store.deviceId, clientId)) _fail(409, '附件标识与草稿不一致');
    final repository = await _repository();
    if (repository == null) _fail(501, '本机附件存储尚未就绪');
    final asset = await repository.get(attachmentBinding(fid, id, store.deviceId), value.id);
    if (asset?.available != true || LocalStore.canonical(asset!.descriptor.toJson()) != LocalStore.canonical(value.toJson())) _fail(409, '附件字节未能完整保存在本机');
    await repository.verifiedFile(attachmentBinding(fid, id, store.deviceId), value.id);
    return store.db.transaction((tx) async {
      await _member(tx, fid);
      final existing = await _document(tx, fid, col(fid, 'messages'), id, includeDeleted: true);
      final pending = await _outbox(tx, fid);
      final old = pending.where((row) => row['client_id'] == clientId).firstOrNull;
      if (old != null && (old['kind'] != value.kind || LocalStore.canonical(old['attachment']) != LocalStore.canonical(value.toJson()))) _fail(409, '同一草稿标识对应不同附件');
      if (existing != null) {
        if (existing['attachment_id'] != value.id || existing['kind'] != value.kind) _fail(409, '同一消息标识对应不同内容');
        await _ackPending(tx, fid, clientId, '');
        return _read(tx, fid, existing);
      }
      if (old != null) return {...old, 'id': id};
      if (pending.length >= maxPending) _fail(409, '本机待发送草稿已达100条');
      final draft = <String, dynamic>{'client_id': clientId, 'body': '', 'kind': value.kind,
        'attachment': value.toJson(), 'created_at': now().toUtc().toIso8601String()};
      pending.add(draft); await _saveOutbox(tx, fid, pending);
      return {...draft, 'id': id};
    });
  }
  /// 每次尝试先查稳定消息ID。即使上次提交结果未知，也先归并回执再决定重试。
  Future<Json> commitPending(String fid, String clientId) {
    if (!_id(fid) || !_id(clientId, 80)) _fail(400, '草稿标识无效');
    final key = (store.deviceId, fid, clientId);
    return _commits.putIfAbsent(key, () => _commitPending(fid, clientId).whenComplete(() { _commits.remove(key); }));
  }
  Future<Json> _commitPending(String fid, String clientId) async {
    final staged = await store.db.transaction((tx) async {
      await _member(tx, fid);
      final id = messageId(fid, store.deviceId, clientId);
      final existing = await _document(tx, fid, col(fid, 'messages'), id, includeDeleted: true);
      if (existing != null) {
        final draft = (await _outbox(tx, fid)).where((row) => row['client_id'] == clientId).firstOrNull;
        if (draft != null) await _checkDraftReceipt(tx, fid, draft, existing);
        await _ackPending(tx, fid, clientId, existing['body'] as String);
        return <String, dynamic>{'receipt': await _read(tx, fid, existing)};
      }
      final draft = (await _outbox(tx, fid)).where((row) => row['client_id'] == clientId).firstOrNull;
      if (draft == null) _fail(404, '待发送草稿不存在');
      return draft;
    });
    if (staged['receipt'] is Map) return Json.from(staged['receipt'] as Map);
    if (staged['attachment'] is Map) {
      final descriptor = _descriptor(fid, messageId(fid, store.deviceId, clientId), store.deviceId, Json.from(staged['attachment'] as Map));
      final repository = await _repository();
      if (repository == null) _fail(501, '本机附件存储尚未就绪');
      final binding = attachmentBinding(fid, descriptor.parentId, store.deviceId);
      final asset = await repository.get(binding, descriptor.id);
      if (asset?.available != true || !asset!.descriptor.same(descriptor)) _fail(409, '本机附件缺件，保留草稿供恢复或删除');
      await repository.verifiedFile(binding, descriptor.id);
    }
    final result = await request('POST', fid, ['chat', 'messages'], body: {'client_id': clientId, 'body': staged['body'], if (staged['attachment'] != null) 'attachment': staged['attachment']}, requirePending: true);
    return Json.from(result!.data as Map);
  }
  Future<void> discardPending(String fid, String clientId) async {
    if (!_id(fid) || !_id(clientId, 80)) _fail(400, '草稿标识无效');
    if (_commits.containsKey((store.deviceId, fid, clientId))) _fail(409, '此草稿正在保存，请稍后再操作');
    await store.db.transaction((tx) async {
      await _member(tx, fid);
      final existing = await _document(tx, fid, col(fid, 'messages'), messageId(fid, store.deviceId, clientId), includeDeleted: true);
      if (existing != null) _fail(409, '消息已提交，请使用本人撤回而不是删除草稿');
      final pending = await _outbox(tx, fid);
      if (_commits.containsKey((store.deviceId, fid, clientId))) _fail(409, '此草稿正在保存，请稍后再操作');
      pending.removeWhere((row) => row['client_id'] == clientId);
      await _saveOutbox(tx, fid, pending);
    });
  }
  Future<List<Json>> _pendingProjection(DatabaseExecutor tx, String fid) async {
    final member = await _member(tx, fid), pending = await _outbox(tx, fid), remaining = <Json>[], result = <Json>[];
    for (final draft in pending) {
      final client = draft['client_id'] as String, id = messageId(fid, store.deviceId, client);
      final existing = await _document(tx, fid, col(fid, 'messages'), id, includeDeleted: true);
      if (existing != null) {
        await _checkDraftReceipt(tx, fid, draft, existing);
        continue;
      }
      remaining.add(draft);
      final inFlight = _commits.containsKey((store.deviceId, fid, client));
      result.add({'id': id, 'family_id': fid, 'sender_id': store.deviceId, ...draft, 'kind': draft['kind'] ?? 'text', 'image': null, 'attachment_status': draft['attachment'] == null ? null : 'available_local',
        'sender_name': member['display_name'], 'sender_emoji': member['avatar_emoji'], 'sender_avatar_url': member['avatar_url'],
        'retracted': false, 'local_pending': true, 'delivery_status': inFlight ? 'committing_local' : 'failed_local'});
    }
    if (remaining.length != pending.length) await _saveOutbox(tx, fid, remaining);
    return result;
  }
  /// 同一SQLite快照中合并已提交消息与本机私有待发送行，避免提交切换时重复或短暂消失。
  Future<List<Json>> localSnapshot(String fid) async {
    final rows = await store.db.transaction((tx) async {
    final rows = [...await _snapshot(tx, fid), ...await _pendingProjection(tx, fid)];
    rows.sort(compareMessages); return rows;
    });
    return _attachmentStates(fid, rows);
  }

  Future<List<Json>> statuses(String fid) => store.db.transaction((tx) async {
    await _member(tx, fid);
    final rows = await tx.query('documents', where: 'space=? AND collection=? AND deleted=0', whereArgs: [fid, col(fid, 'status')]);
    final result = <Json>[];
    for (final row in rows) {
      final data = Json.from(jsonDecode(row['data'] as String) as Map), actor = row['id'];
      if (data['family_id'] != fid || data['created_by'] != actor || !_id(actor)) continue;
      final member = await _document(tx, fid, '/families/$fid/members', actor as String);
      if (member == null || member['status'] != 'active' || member['family_id'] != fid || member['user_id'] != actor) continue;
      result.add({'id': actor, 'family_id': fid, 'created_by': actor, 'emoji': data['emoji'], 'text': data['text'], 'updated_at': data['updated_at'],
        'sender_name': member['display_name'], 'sender_emoji': member['avatar_emoji'], 'sender_avatar_url': member['avatar_url']});
    }
    result.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    return result;
  });

  Future<LocalResult?> request(String method, String fid, List<String> tail,
    {Json body = const {}, Json query = const {}, bool requirePending = false}) async {
    if (tail.length < 2 || tail[0] != 'chat') return null;
    final messages = tail[1] == 'messages';
    final status = tail[1] == 'status' && tail.length == 2;
    if (!messages && !status) return null;
    if (messages && tail.length > 3) _fail(501, '旧聊天原件端点不可用，请使用独立聊天副本入口；未读取回忆原件');
    if (messages && tail.length == 3 && tail[2] == 'image') _fail(501, '旧图片上传端点不可用，请使用独立聊天副本入口；回忆原件不会作为聊天附件发送');
    if (!_id(fid) || tail.length == 3 && !_id(tail[2])) _fail(400, '标识无效');
    final verb = method.toUpperCase();
    if (status && verb == 'GET') {
      _only(query, {}); _only(body, {}); return (data: await statuses(fid), meta: null);
    }
    if (messages && verb == 'GET') {
      _only(body, {});
      _only(query, {'limit', 'after_created_at', 'after_id'});
      final raw = query['limit'] ?? 100;
      final limit = raw is int ? raw : raw is String ? int.tryParse(raw) : null;
      if (limit == null || limit < 1 || limit > 200) _fail(400, '每页数量须为1至200');
      final after = query['after_created_at'], afterId = query['after_id'];
      if ((after == null) != (afterId == null)) _fail(400, '历史时间和标识必须成对提供');
      final date = after is String ? DateTime.tryParse(after) : null;
      if (after != null && (date == null || !_id(afterId))) _fail(400, '历史游标无效');
      final all = await snapshot(fid);
      if (tail.length == 3) {
        final row = all.where((row) => row['id'] == tail[2]).firstOrNull;
        if (row == null) _fail(404, '消息不存在');
        return (data: row, meta: null);
      }
      // 仅兼容旧的历史读取接口；新本地 UI 和设备同步均不使用此时间游标。
      final filtered = after == null ? all : all.where((row) {
        final order = DateTime.parse(row['created_at'] as String).compareTo(date!);
        return order > 0 || order == 0 && (row['id'] as String).compareTo(afterId as String) > 0;
      }).toList();
      final page = filtered.take(limit).toList();
      final memberRows = await store.list(fid, '/families/$fid/members');
      return (data: page, meta: {'cursor': filtered.length > limit && page.isNotEmpty ? '${page.last['created_at']}|${page.last['id']}' : null,
        'limit': limit, 'active_member_ids': [for (final member in memberRows) if (member['status'] == 'active' && member['family_id'] == fid) member['user_id']]});
    }
    _only(query, {});
    if (messages && !((tail.length == 2 && verb == 'POST') || (tail.length == 3 && verb == 'DELETE'))) _fail(405, '消息只支持创建、读取和本人撤回');
    if (status && !['PUT', 'PATCH', 'DELETE'].contains(verb)) _fail(405, '状态不支持此方法');
    late LocalResult result;
    AttachmentDescriptor? withdrawnAttachment;
    await store.batchComputed((tx) async {
      await _member(tx, fid);
      if (status) {
        final collection = col(fid, 'status');
        if (verb == 'DELETE') {
          _only(body, {});
          // 状态可重设，所以清空字段而不设置永久 tombstone。
          final fields = {'family_id': fid, 'created_by': store.deviceId, 'emoji': '', 'text': '', 'updated_at': now().toUtc().toIso8601String()};
          result = (data: fields, meta: null);
          return [{'space': fid, 'collection': collection, 'id': store.deviceId, 'fields': fields}];
        }
        _only(body, {'emoji', 'text'});
        final emoji = _text(body['emoji'] ?? '', 16, empty: true), text = _text(body['text'] ?? '', 80, empty: true);
        final fields = {'family_id': fid, 'created_by': store.deviceId, 'emoji': emoji, 'text': text, 'updated_at': now().toUtc().toIso8601String()};
        result = (data: fields, meta: null);
        return [{'space': fid, 'collection': collection, 'id': store.deviceId, 'fields': fields}];
      }
      final collection = col(fid, 'messages');
      if (verb == 'DELETE') {
        _only(body, {});
        final row = await _document(tx, fid, collection, tail[2], includeDeleted: true);
        if (row == null) _fail(404, '消息不存在');
        if (row['created_by'] != store.deviceId || row['family_id'] != fid) _fail(403, '只能撤回本人发送的消息');
        if (row['retracted'] != true && row['attachment_id'] is String) {
          final raw = await _document(tx, fid, col(fid, 'attachments'), row['attachment_id'] as String);
          if (raw != null) withdrawnAttachment = _descriptor(fid, tail[2], store.deviceId, raw);
        }
        result = (data: {...await _read(tx, fid, row), 'body': null, 'attachment': null, 'attachment_status': null, 'retracted': true}, meta: null);
        if (row['retracted'] == true) return <Json>[];
        return [{'space': fid, 'collection': collection, 'id': tail[2], 'fields': <String, dynamic>{}, 'delete': true},
          if (row['attachment_id'] is String) {'space': fid, 'collection': col(fid, 'attachments'), 'id': row['attachment_id'], 'fields': <String, dynamic>{}, 'delete': true}];
      }
      _only(body, {'client_id', 'body', 'attachment'});
      final client = body['client_id'];
      if (!_id(client, 80)) _fail(400, 'client_id 无效');
      final id = messageId(fid, store.deviceId, client as String);
      final rawAttachment = body['attachment'];
      if (rawAttachment != null && rawAttachment is! Map) _fail(400, '附件描述无效');
      final descriptor = rawAttachment == null ? null : _descriptor(fid, id, store.deviceId, Json.from(rawAttachment as Map));
      if (descriptor != null && descriptor.id != attachmentId(fid, store.deviceId, client)) _fail(409, '附件标识不一致');
      if (descriptor != null && !requirePending) _fail(409, '附件必须先冻结为本机待发送草稿');
      final kind = descriptor?.kind ?? 'text';
      final text = descriptor == null ? _text(body['body'], 2000) : _text(body['body'], 0, empty: true);
      final old = await _document(tx, fid, collection, id, includeDeleted: true);
      if (old != null) {
        if (old['body'] != text || old['created_by'] != store.deviceId || old['client_id'] != client || old['kind'] != kind || old['attachment_id'] != descriptor?.id) _fail(409, '相同 client_id 对应不同聊天内容');
        if (descriptor != null) {
          final saved = await _document(tx, fid, col(fid, 'attachments'), descriptor.id, includeDeleted: false);
          if (old['retracted'] != true && (saved == null || !_descriptor(fid, id, store.deviceId, saved).same(descriptor))) _fail(409, '同一消息标识对应不同附件描述');
        }
        await _ackPending(tx, fid, client, text);
        result = (data: await _read(tx, fid, old), meta: null); return <Json>[];
      }
      final staged = (await _outbox(tx, fid)).where((row) => row['client_id'] == client).firstOrNull;
      if (requirePending && staged == null) _fail(409, '待发送草稿已撤销，未创建消息');
      if (staged != null && (staged['body'] != text || LocalStore.canonical(staged['attachment']) != LocalStore.canonical(descriptor?.toJson()))) _fail(409, '同一草稿标识对应不同正文');
      if (descriptor != null) {
        final existingDescriptor = await _document(tx, fid, col(fid, 'attachments'), descriptor.id, includeDeleted: true);
        if (existingDescriptor != null) {
          final raw = Json.from(existingDescriptor)..remove('retracted');
          if (existingDescriptor['retracted'] == true || !_descriptor(fid, id, store.deviceId, raw).same(descriptor)) _fail(409, '附件描述已撤回或与草稿不一致');
        }
      }
      final fields = {'family_id': fid, 'created_by': store.deviceId, 'client_id': client,
        'kind': kind, 'body': text, if (descriptor != null) 'attachment_id': descriptor.id, 'created_at': staged?['created_at'] ?? now().toUtc().toIso8601String()};
      // 私有草稿确认与业务操作日志在batchComputed同一事务内提交。
      await _ackPending(tx, fid, client, text);
      result = (data: {...await _read(tx, fid, {...fields, 'id': id}), if (descriptor != null) 'attachment': descriptor.toJson()}, meta: null);
      return [{'space': fid, 'collection': collection, 'id': id, 'fields': fields},
        if (descriptor != null) {'space': fid, 'collection': col(fid, 'attachments'), 'id': descriptor.id,
          'fields': Map<String, dynamic>.from(descriptor.toJson())..remove('id')}];
    });
    final withdrawn = withdrawnAttachment;
    if (withdrawn != null) {
      // 逻辑撤回已事务提交；清理失败不恢复授权，读取与同步仍以live业务记录为门禁。
      try {
        final repository = await _repository();
        if (repository != null) await repository.deleteLocal(attachmentBinding(fid, withdrawn.parentId, withdrawn.authorDeviceId), withdrawn.id);
      } catch (_) {}
    }
    return result;
  }
}
