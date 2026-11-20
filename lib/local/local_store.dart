import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

typedef Json = Map<String, dynamic>;

/// SQLite 是事实源；业务变更、可重试日志与本机应用顺序在同一事务内提交。
/// 原照/原视频句柄和服务凭据不进入 documents/operations。
class LocalStore {
  LocalStore._(this.db, this.deviceId);
  final Database db;
  final String deviceId;
  static const maxOperationBytes = 1024 * 1024;
  static const maxBatchBytes = 8 * 1024 * 1024;
  static final _identifier = RegExp(r'^[a-zA-Z0-9_-]{1,100}$');
  static const _maxInt = 9007199254740991;

  static Future<LocalStore> open({DatabaseFactory? factory, String? path}) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(path ?? p.join(await getDatabasesPath(), 'wo-rebuild-local-v1.sqlite'),
      options: OpenDatabaseOptions(version: 1, onCreate: (db, _) async {
        await db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        await db.execute('CREATE TABLE documents (space TEXT NOT NULL, collection TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL, versions TEXT NOT NULL, deleted INTEGER NOT NULL, revision INTEGER NOT NULL, PRIMARY KEY(space,collection,id))');
        await db.execute('CREATE TABLE operations (space TEXT NOT NULL, actor TEXT NOT NULL, sequence INTEGER NOT NULL, clock INTEGER NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(space,actor,sequence))');
        await db.execute('CREATE TABLE changes (revision INTEGER PRIMARY KEY AUTOINCREMENT, space TEXT NOT NULL, collection TEXT NOT NULL, id TEXT NOT NULL)');
        await db.execute('CREATE TABLE device_refs (id TEXT PRIMARY KEY, kind TEXT NOT NULL, locator TEXT NOT NULL, metadata TEXT NOT NULL)');
        await db.execute('CREATE INDEX documents_changes ON documents(space,revision)');
      }),);
    final id = await db.transaction((tx) async {
      final existing = await _readMeta(tx, 'device');
      if (existing != null) return existing;
      final created = const Uuid().v4();
      await _writeMeta(tx, 'device', created);
      return created;
    });
    return LocalStore._(db, id as String);
  }

  static Future<dynamic> _readMeta(DatabaseExecutor db, String key) async {
    final rows = await db.query('meta', where: 'key=?', whereArgs: [key]);
    return rows.isEmpty ? null : jsonDecode(rows.single['value'] as String);
  }
  static Future<void> _writeMeta(DatabaseExecutor db, String key, Object? value) async {
    if (value == null) { await db.delete('meta', where: 'key=?', whereArgs: [key]); return; }
    await db.insert('meta', {'key': key, 'value': jsonEncode(value)}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  Future<dynamic> privateValue(String key) => _readMeta(db, 'private:$key');
  Future<void> setPrivate(String key, Object? value) => _writeMeta(db, 'private:$key', value);

  static Object? _ordered(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _ordered(value[key])};
    }
    if (value is List) return value.map(_ordered).toList();
    return value;
  }
  static String canonical(Object? value) => jsonEncode(_ordered(value));
  static void _location(String space, String collection, String id) {
    if (!_identifier.hasMatch(space) || !_identifier.hasMatch(id) ||
        !collection.startsWith('/families/$space/') || collection.endsWith('/') ||
        collection.split('/').skip(1).any((part) => !_identifier.hasMatch(part))) {
      throw const FormatException('文档不属于此空间或标识无效');
    }
  }
  static Json _operation(String space, Json value) {
    final actor = value['actor'], seq = value['sequence'], clock = value['clock'];
    if (value['space'] != space || actor is! String || !_identifier.hasMatch(actor) ||
        seq is! int || seq < 1 || seq > _maxInt || clock is! int || clock < 1 || clock > _maxInt ||
        value['collection'] is! String || value['id'] is! String ||
        !['patch', 'delete'].contains(value['kind']) || value['fields'] is! Map) {
      throw const FormatException('操作日志无效或跨空间');
    }
    _location(space, value['collection'] as String, value['id'] as String);
    final fields = Map<String, dynamic>.from(value['fields'] as Map);
    if (fields.length > 256 || fields.containsKey('id') || fields.keys.any((k) => k.startsWith('_')) ||
        fields.keys.any((k) => ['locator','bookmark','asset_id','api_key','access_token','password'].contains(k))) {
      throw const FormatException('业务字段无效；本机句柄和凭据不能进入同步日志');
    }
    final normalized = {'space': space, 'actor': actor, 'sequence': seq, 'clock': clock,
      'collection': value['collection'], 'id': value['id'], 'kind': value['kind'], 'fields': fields};
    if (utf8.encode(canonical(normalized)).length > maxOperationBytes) throw const FormatException('单条操作过大');
    return normalized;
  }

  Future<Json> patch(String space, String collection, String id, Json fields, {bool delete = false}) async =>
      (await batch([{'space':space,'collection':collection,'id':id,'fields':fields,'delete':delete}])).single;

  /// 多文档业务和非秘密本机索引原子提交；失败不留下半家庭或计数间隙。
  Future<List<Json>> batch(List<Json> changes, {Json privateUpdates = const {}}) async {
    if (changes.length > 256) throw const FormatException('本地批次过大');
    return db.transaction((tx) async {
      final result = <Json>[];
      final scopes = <String>{};
      var batchBytes = 2;
      for (final change in changes) {
        final space = change['space'] as String, collection = change['collection'] as String, id = change['id'] as String;
        _location(space,collection,id);
        final seq = ((await _readMeta(tx, 'seq:$space')) as int? ?? 0) + 1;
        final clock = ((await _readMeta(tx, 'clock:$space')) as int? ?? 0) + 1;
        final op = _operation(space, {'space': space, 'actor': deviceId, 'sequence': seq,
          'clock': clock, 'collection': collection, 'id': id, 'kind': change['delete'] == true ? 'delete' : 'patch', 'fields': change['fields']});
        batchBytes += utf8.encode(canonical(op)).length + 1;
        if (batchBytes > maxBatchBytes) throw const FormatException('本地批次字节过大');
        await _accept(tx, op);
        await _writeMeta(tx, 'seq:$space', seq);
        await _writeMeta(tx, 'clock:$space', clock);
        result.add(op); scopes.add(space);
      }
      for (final scope in scopes) { await _advance(tx, scope, {deviceId}); }
      for (final entry in privateUpdates.entries) { await _writeMeta(tx, 'private:${entry.key}', entry.value); }
      return result;
    });
  }

  static bool _newer(Json old, Json op) =>
      (op['clock'] as int) > (old['clock'] as int) ||
      (op['clock'] == old['clock'] && (op['actor'] as String).compareTo(old['actor'] as String) > 0);

  Future<bool> _accept(Transaction tx, Json op) async {
    final where = [op['space'], op['collection'], op['id']];
    final payload = canonical(op);
    final existing = await tx.query('operations', where: 'space=? AND actor=? AND sequence=?', whereArgs: [op['space'], op['actor'], op['sequence']]);
    if (existing.isNotEmpty) {
      if (existing.single['payload'] != payload) throw const FormatException('同一操作 ID 对应不同内容');
      return false;
    }
    await tx.insert('operations', {'space': op['space'], 'actor': op['actor'], 'sequence': op['sequence'], 'clock': op['clock'], 'payload': payload});
    final rows = await tx.query('documents', where: 'space=? AND collection=? AND id=?', whereArgs: where);
    final data = rows.isEmpty ? <String,dynamic>{} : Map<String,dynamic>.from(jsonDecode(rows.single['data'] as String) as Map);
    final versions = rows.isEmpty ? <String,dynamic>{} : Map<String,dynamic>.from(jsonDecode(rows.single['versions'] as String) as Map);
    var deleted = rows.isNotEmpty && rows.single['deleted'] == 1;
    var changed = rows.isEmpty;
    if (op['kind'] == 'delete') { changed = !deleted || changed; deleted = true; }
    for (final entry in (op['fields'] as Json).entries) {
      final old = versions[entry.key];
      if (old == null || _newer(Map<String,dynamic>.from(old as Map), op)) {
        data[entry.key] = entry.value;
        versions[entry.key] = {'clock': op['clock'], 'actor': op['actor']};
        changed = true;
      }
    }
    if (changed) {
      final revision = await tx.insert('changes', {'space': op['space'], 'collection': op['collection'], 'id': op['id']});
      await tx.insert('documents', {'space': op['space'], 'collection': op['collection'], 'id': op['id'],
        'data': canonical(data), 'versions': canonical(versions), 'deleted': deleted ? 1 : 0, 'revision': revision}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return true;
  }

  static Future<void> _advance(Transaction tx, String space, Set<String> actors) async {
    final vector = Map<String,dynamic>.from((await _readMeta(tx, 'vector:$space') as Map?) ?? {});
    for (final actor in actors) {
      var seq = vector[actor] as int? ?? 0;
      while ((await tx.query('operations', columns: ['sequence'], where: 'space=? AND actor=? AND sequence=?', whereArgs: [space,actor,seq+1], limit: 1)).isNotEmpty) { seq++; }
      vector[actor] = seq;
    }
    await _writeMeta(tx, 'vector:$space', vector);
  }

  Future<int> merge(String space, List<Json> input) async {
    if (!_identifier.hasMatch(space) || input.length > 256) throw const FormatException('空间无效或批次过大');
    final ops = input.map((v) => _operation(space,v)).toList();
    if (utf8.encode(canonical(ops)).length > maxBatchBytes) throw const FormatException('批次字节过大');
    return db.transaction((tx) async {
      var accepted = 0;
      var clock = await _readMeta(tx, 'clock:$space') as int? ?? 0;
      final actors = <String>{};
      for (final op in ops) {
        if (op['actor'] == deviceId && (await tx.query('operations', where: 'space=? AND actor=? AND sequence=?', whereArgs: [space,deviceId,op['sequence']], limit: 1)).isEmpty) {
          throw const FormatException('远端不能创建本机身份的新操作');
        }
        if (await _accept(tx, op)) accepted++;
        if ((op['clock'] as int) > clock) clock = op['clock'] as int;
        actors.add(op['actor'] as String);
      }
      await _writeMeta(tx, 'clock:$space', clock);
      await _advance(tx, space, actors);
      return accepted;
    });
  }

  Future<Map<String,int>> vector(String space) async => Map<String,int>.from((await _readMeta(db, 'vector:$space') as Map?) ?? {});
  Future<List<Json>> exportSince(String space, Map<String,int> vector, {int limit = 200, int maxBytes = 2 * 1024 * 1024}) async {
    if (!_identifier.hasMatch(space) || vector.length > 128 || limit < 1 || limit > 256 || maxBytes < maxOperationBytes || maxBytes > maxBatchBytes ||
        vector.entries.any((e) => !_identifier.hasMatch(e.key) || e.value < 0 || e.value > _maxInt)) throw const FormatException('增量请求无效');
    final actors = vector.keys.toList();
    final where = actors.isEmpty ? 'space=?' : 'space=? AND (actor NOT IN (${List.filled(actors.length, '?').join(',')}) OR ${actors.map((_) => '(actor=? AND sequence>?)').join(' OR ')})';
    final args = <Object?>[space,...actors,for(final actor in actors)...[actor,vector[actor]]];
    final rows = await db.query('operations', where: where, whereArgs: args, orderBy: 'clock,actor,sequence', limit: limit);
    final result = <Json>[]; var bytes = 2;
    for (final row in rows) {
      final payload = row['payload'] as String;
      final size = utf8.encode(payload).length + 1;
      if (bytes + size > maxBytes) break;
      bytes += size; result.add(Map<String,dynamic>.from(jsonDecode(payload) as Map));
    }
    return result;
  }

  Future<Json?> get(String space, String collection, String id) async {
    _location(space,collection,id);
    final rows = await db.query('documents', where: 'space=? AND collection=? AND id=? AND deleted=0', whereArgs: [space,collection,id]);
    return rows.isEmpty ? null : {...Map<String,dynamic>.from(jsonDecode(rows.single['data'] as String) as Map),'id':id};
  }
  Future<List<Json>> list(String space, String collection, {int afterRevision = 0}) async {
    _location(space,collection,'validate');
    final rows = await db.query('documents', where: 'space=? AND collection=? AND deleted=0 AND revision>?', whereArgs: [space,collection,afterRevision], orderBy: 'revision,id');
    return [for(final row in rows) {...Map<String,dynamic>.from(jsonDecode(row['data'] as String) as Map),'id':row['id']}];
  }
  Future<int> revision(String space, String collection, String id) async {
    _location(space,collection,id);
    final rows = await db.query('documents', columns:['revision'], where:'space=? AND collection=? AND id=?', whereArgs:[space,collection,id]);
    return rows.isEmpty ? 0 : rows.single['revision'] as int;
  }
  Future<void> saveDeviceReference(String id, String kind, String locator, Json metadata) async {
    if (!_identifier.hasMatch(id) || !['photo','video','restored-file'].contains(kind)) throw const FormatException('本机媒体引用无效');
    await db.insert('device_refs', {'id':id,'kind':kind,'locator':locator,'metadata':canonical(metadata)}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  Future<Json?> deviceReference(String id) async {
    final rows = await db.query('device_refs', where:'id=?',whereArgs:[id]);
    return rows.isEmpty ? null : Map<String,dynamic>.from(rows.single);
  }
  Future<void> close() => db.close();
}
