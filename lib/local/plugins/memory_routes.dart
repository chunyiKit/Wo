import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../local_backend.dart';
import '../local_media_repository.dart';
import '../local_store.dart';

/// 权限空间由本机已确认身份/伴侣绑定决定，不能从请求 body 推导授权。
abstract interface class MemoryAccess {
  Future<List<String>> visibleSpaces(String familyId);
  Future<String> spaceFor(String familyId, String visibility);
}

typedef _LocatedMemory = ({String space, Json row});

/// 只在已授权空间读取正文、计数、媒体和留言。私密正文从不先写 family 再过滤。
class MemoryRoutes {
  MemoryRoutes(this.store, {required this.media, required this.access,
    DateTime Function()? now}) : _now = now ?? DateTime.now;

  final LocalStore store;
  final LocalMediaRepository media;
  final MemoryAccess access;
  final DateTime Function() _now;
  static const _uuid = Uuid();
  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,100}$');
  static final _clientId = RegExp(r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$');
  static const _fields = {'title','body','mood','location','visibility','event_date'};
  static const _visibilities = {'family','private','couple'};
  static final _queues = Expando<Map<String, Future<void>>>();

  String _collection(String space) => '/families/$space/plugins/memory/memories';
  String _comments(String space, String memoryId) => '${_collection(space)}/$memoryId/comments';
  String get _stamp => _now().toUtc().toIso8601String();
  static Never _error(int status, String message) => throw ApiException(
    switch (status) {403=>'FORBIDDEN',404=>'NOT_FOUND',405=>'METHOD_NOT_ALLOWED',409=>'CONFLICT',501=>'FEATURE_UNAVAILABLE',_=>'VALIDATION_ERROR'},
    message, statusCode: status);
  static void _only(Json body, Set<String> allowed) {
    if (body.keys.any((key) => !allowed.contains(key))) _error(400,'包含未知或只读字段');
  }
  static String _text(Object? value, String label, int max) {
    if (value is! String || value.trim().isEmpty || value.runes.length > max) _error(400,'$label 为空或超过长度限制');
    return value.trim();
  }
  static String? _optional(Object? value, String label, int max) {
    if (value == null) return null;
    if (value is! String || value.runes.length > max) _error(400,'$label 无效或过长');
    return value;
  }
  static String _date(Object? value) {
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) _error(400,'日期必须是 YYYY-MM-DD');
    final d = DateTime.tryParse(value);
    if (d == null || d.year < 1 || d.year > 9999) _error(400,'日期不存在');
    final normalized = [d.year.toString().padLeft(4,'0'),d.month.toString().padLeft(2,'0'),d.day.toString().padLeft(2,'0')].join('-');
    if (normalized != value) _error(400,'日期不存在');
    return value;
  }
  static void _identifier(String value) { if (!_id.hasMatch(value)) _error(400,'标识无效'); }
  Future<void> _member(String fid) async {
    _identifier(fid);
    final m = await store.get(fid,'/families/$fid/members',store.deviceId);
    if (m == null || m['status'] != 'active' || m['family_id'] != fid || m['user_id'] != store.deviceId) _error(403,'本机没有有效家庭成员身份');
  }
  Future<List<String>> _spaces(String fid) async {
    await _member(fid);
    final spaces = (await access.visibleSpaces(fid)).toSet().toList()..sort();
    if (!spaces.contains(fid)) _error(403,'未获授权的家庭空间');
    for (final space in spaces) { _identifier(space); }
    return spaces;
  }
  Future<String> _target(String fid, String visibility) async {
    if (!_visibilities.contains(visibility)) _error(400,'可见范围无效');
    final space = await access.spaceFor(fid,visibility);
    _identifier(space);
    if ((visibility == 'family') != (space == fid)) _error(403,'受限回忆必须使用独立权限空间');
    if (!(await _spaces(fid)).contains(space)) _error(403,'未获授权的回忆空间');
    return space;
  }
  Future<bool> _validRow(String fid,String space,Json row) async {
    if (row['family_id'] != fid || !_visibilities.contains(row['visibility'])) return false;
    if (row['visibility'] == 'family') return space == fid;
    if (space == fid) return false;
    if (row['visibility'] == 'private' && row['created_by'] != store.deviceId) return false;
    try {return await _target(fid,row['visibility'] as String) == space;}
    on ApiException {return false;}
  }
  Future<_LocatedMemory?> _find(String fid,String id,{List<String>? spaces}) async {
    _identifier(id);
    _LocatedMemory? found;
    for (final space in spaces ?? await _spaces(fid)) {
      final row = await store.get(space,_collection(space),id);
      if (row == null || !await _validRow(fid,space,row)) continue;
      if (found != null) _error(409,'可见空间存在记录标识冲突，请先解决冲突');
      found = (space:space,row:row);
    }
    return found;
  }
  Future<_LocatedMemory> _load(String fid,String id) async {
    final found = await _find(fid,id);
    if (found == null) _error(404,'回忆不存在');
    return found;
  }
  Future<T> _serialize<T>(String fid,Future<T> Function() action) {
    final queues = _queues[store] ??= <String,Future<void>>{};
    final result = Completer<T>();
    queues[fid] = (queues[fid] ?? Future<void>.value()).then((_) async {
      try {result.complete(await action());} catch (e,s) {result.completeError(e,s);}
    });
    return result.future;
  }

  Future<LocalResult?> request(String method,String fid,List<String> tail,{
    Json body=const {},Json query=const {},
  }) async {
    if (tail.length < 2 || tail[0] != 'memory' || tail[1] != 'memories') return null;
    final known = tail.length == 2 || tail.length == 3 ||
      (tail.length == 4 && ['comments','media'].contains(tail[3])) ||
      (tail.length == 5 && ['comments','media'].contains(tail[3])) ||
      (tail.length == 6 && tail[3] == 'media' && ['raw','presign','commit'].contains(tail[5]));
    if (!known) return null;
    await _spaces(fid);
    final verb = method.toUpperCase();
    if (verb == 'GET') return _request(verb,fid,tail,body,query);
    return _serialize(fid,()=>_request(verb,fid,tail,body,query));
  }
  Future<LocalResult> _request(String verb,String fid,List<String> tail,Json body,Json query) async {
    if (tail.length == 2) {
      if (verb == 'GET') return _page(fid,query);
      if (verb != 'POST') _error(405,'此路由不支持该方法');
      _only(query,<String>{});
      return (data:await _create(fid,body),meta:null);
    }
    _only(query,<String>{});
    if (tail.length == 3 && verb == 'DELETE') {
      _only(body,<String>{});await _delete(fid,tail[2]);return (data:null,meta:null);
    }
    final found = await _load(fid,tail[2]);
    if (tail.length == 3) {
      if (verb == 'GET') return (data:await _read(fid,found,detail:true),meta:null);
      if (!['PUT','PATCH'].contains(verb)) _error(405,'此路由不支持该方法');
      return (data:await _update(fid,found,body),meta:null);
    }
    if (tail[3] == 'comments') {
      if (tail.length == 4 && verb == 'POST') return (data:await _addComment(fid,found,body),meta:null);
      if (tail.length == 5 && verb == 'DELETE') {
        _only(body,<String>{});await _deleteComment(found,tail[4]);return (data:null,meta:null);
      }
      _error(405,'留言不支持该方法');
    }
    if (tail.length == 4 && verb == 'POST') {
      _only(body,{'media_id'});
      final id = body['media_id'];if (id is! String) _error(400,'请选择本机媒体引用，不能上传重编码文件');
      return (data:await _attach(fid,found,id),meta:null);
    }
    if (tail.length == 5 && verb == 'DELETE') {
      _only(body,<String>{});await _removeMedia(found,tail[4]);return (data:null,meta:null);
    }
    if (tail.length == 6 || (tail.length == 5 && ['presign','commit'].contains(tail[4]))) _error(501,'本地回忆不使用云上传票据或原件 raw 网络端点');
    _error(405,'媒体不支持该方法');
  }

  Json _values(Json body,{required bool create}) {
    _only(body,create?{..._fields,'client_id'}:_fields);
    final values = <String,dynamic>{};
    if (create || body.containsKey('title')) values['title'] = _text(body['title'],'标题',80);
    for (final entry in {'body':2000,'mood':16,'location':80}.entries) {
      if (create || body.containsKey(entry.key)) values[entry.key] = _optional(body[entry.key],entry.key,entry.value);
    }
    if (create || body.containsKey('visibility')) {
      final v = body.containsKey('visibility') ? body['visibility'] : 'private';
      if (v is! String || !_visibilities.contains(v)) _error(400,'可见范围无效');
      values['visibility'] = v;
    }
    if (create || body.containsKey('event_date')) {
      final today = _now();
      final fallback = [today.year.toString().padLeft(4,'0'),today.month.toString().padLeft(2,'0'),today.day.toString().padLeft(2,'0')].join('-');
      values['event_date'] = _date(!body.containsKey('event_date') && create ? fallback : body['event_date']);
    }
    return values;
  }
  Future<Json> _create(String fid,Json body) async {
    final fields = _values(body,create:true);
    final client = body['client_id'];
    if (client != null && (client is! String || !_clientId.hasMatch(client))) _error(400,'client_id 必须是稳定 UUID');
    final id = client is String ? client.toLowerCase() : _uuid.v4();
    final visibility = fields['visibility'] as String;
    final space = await _target(fid,visibility);
    final old = await _find(fid,id);
    if (old != null) {
      if (old.row['created_by'] != store.deviceId || old.space != space || old.row['visibility'] != visibility) _error(409,'client_id 已用于其他资源或可见范围');
      return _read(fid,old,detail:true);
    }
    for (final visible in await _spaces(fid)) {
      if (await store.revision(visible,_collection(visible),id) > 0) _error(409,'已删除的 client_id 不能复用');
    }
    final stamp = _stamp;
    await store.patch(space,_collection(space),id,{
      ...fields,'family_id':fid,'created_by':store.deviceId,
      'created_at':stamp,'updated_at':stamp,
    });
    return _read(fid,await _load(fid,id),detail:true);
  }
  Future<Json> _update(String fid,_LocatedMemory found,Json body) async {
    final fields = _values(body,create:false);
    if (fields.containsKey('visibility') && fields['visibility'] != found.row['visibility']) _error(409,'创建后的可见范围不能直接修改，需要独立迁移以保护历史内容');
    if (fields.isNotEmpty) await store.patch(found.space,_collection(found.space),found.row['id'] as String,{...fields,'updated_at':_stamp});
    return _read(fid,await _load(fid,found.row['id'] as String),detail:true);
  }
  Future<void> _delete(String fid,String id) async {
    final spaces = await _spaces(fid);
    final found = await _find(fid,id,spaces:spaces);
    final candidates = found == null ? <String>[] : [found.space];
    if (found == null) {
      // 重试只承认已授权空间的真实墓碑，不把任意不存在的 ID 当删除成功。
      for (final space in spaces) {
        if (await store.get(space,_collection(space),id) == null &&
            await store.revision(space,_collection(space),id) > 0) candidates.add(space);
      }
      if (candidates.isEmpty) _error(404,'回忆不存在');
    }
    for (final space in candidates) {
      final children = await store.list(space,_comments(space,id));
      if (found != null) await store.patch(space,_collection(space),id,{},delete:true);
      // 先隐藏父记录；大量留言分批清理失败可按父墓碑继续重试，不再暴露正文。
      for (var start=0;start<children.length;start+=256) {
        await store.batch([for (final child in children.skip(start).take(256)) {
          'space':space,'collection':_comments(space,id),'id':child['id'],
          'fields':<String,dynamic>{},'delete':true,
        }]);
      }
      for (final item in await media.forMemory(space,id)) {await media.detach(space,id,item.id);}
    }
  }
  Future<Json?> _author(String fid,Object? author) async {
    if (author is! String || !_id.hasMatch(author)) return null;
    final m = await store.get(fid,'/families/$fid/members',author);
    return m != null && m['status'] == 'active' && m['family_id'] == fid && m['user_id'] == author ? m : null;
  }
  Future<Json> _commentRead(String fid,Json row) async {
    final author = await _author(fid,row['created_by']);
    return {'id':row['id'],'body':row['body'],'author_id':row['created_by'],
      'author_name':author?['display_name'],'author_emoji':author?['avatar_emoji'],
      'author_avatar_url':author?['avatar_url'],'created_at':row['created_at']};
  }
  Json _mediaRead(String memoryId,LocalMediaItem item,int order) => {
    'id':item.id,'memory_id':memoryId,'kind':item.kind,'url':item.url,
    'content_type':item.contentType,'size_bytes':item.sizeBytes,
    'width':item.width,'height':item.height,'duration_ms':item.durationMs,'sort_order':order,
  };
  Future<Json> _read(String fid,_LocatedMemory found,{bool detail=false}) async {
    final row = found.row,id = row['id'] as String;
    final author = await _author(fid,row['created_by']);
    final comments = (await store.list(found.space,_comments(found.space,id))).where((c)=>c['memory_id'] == id && c['family_id'] == fid).toList();
    comments.sort((a,b){final cmp=DateTime.parse(a['created_at'] as String).compareTo(DateTime.parse(b['created_at'] as String));return cmp!=0?cmp:(a['id'] as String).compareTo(b['id'] as String);});
    final attached = await media.forMemory(found.space,id);
    // 响应也用白名单，不把同步/历史文档里的任意附加字段重新导出。
    return {'id':row['id'],'family_id':fid,'title':row['title'],'body':row['body'],
      'mood':row['mood'],'location':row['location'],'visibility':row['visibility'],
      'event_date':row['event_date'],'created_by':row['created_by'],
      'created_at':row['created_at'],'updated_at':row['updated_at'],
      'author_name':author?['display_name'],'author_emoji':author?['avatar_emoji'],
      'author_avatar_url':author?['avatar_url'],'comment_count':comments.length,
      'comments':detail?[for(final c in comments)await _commentRead(fid,c)]:<Json>[],
      'media':[for(var index=0;index<attached.length;index++)_mediaRead(id,attached[index],index)]};
  }
  Future<Json> _addComment(String fid,_LocatedMemory found,Json body) async {
    _only(body,{'body'});
    final text = _text(body['body'],'留言',500),id = _uuid.v4();
    final memoryId = found.row['id'] as String;
    await store.patch(found.space,_comments(found.space,memoryId),id,{
      'family_id':fid,'memory_id':memoryId,'body':text,'created_by':store.deviceId,'created_at':_stamp,
    });
    return _commentRead(fid,(await store.get(found.space,_comments(found.space,memoryId),id))!);
  }
  Future<void> _deleteComment(_LocatedMemory found,String id) async {
    _identifier(id);
    final memoryId = found.row['id'] as String;
    final row = await store.get(found.space,_comments(found.space,memoryId),id);
    if (row == null || row['memory_id'] != memoryId || row['family_id'] != found.row['family_id']) _error(404,'留言不存在');
    if (row['created_by'] != store.deviceId) _error(403,'只能删除自己的留言');
    await store.patch(found.space,_comments(found.space,memoryId),id,{},delete:true);
  }
  Future<Json> _attach(String fid,_LocatedMemory found,String mediaId) async {
    _identifier(mediaId);
    final memoryId = found.row['id'] as String;
    final before = await media.forMemory(found.space,memoryId);
    if (!before.any((m)=>m.id==mediaId) && before.length>=9) _error(400,'最多添加9个照片或视频');
    await media.attach(found.space,memoryId,mediaId);
    final after = await media.forMemory(found.space,memoryId);
    final index = after.indexWhere((m)=>m.id==mediaId);
    if (index<0) _error(409,'本机媒体未完成挂接，请保留引用后重试');
    return _mediaRead(memoryId,after[index],index);
  }
  Future<void> _removeMedia(_LocatedMemory found,String mediaId) async {
    _identifier(mediaId);
    final memoryId=found.row['id'] as String;
    if (!(await media.forMemory(found.space,memoryId)).any((m)=>m.id==mediaId)) _error(404,'媒体不存在');
    await media.detach(found.space,memoryId,mediaId);
  }
  Future<Json> attachMedia(String fid,String memoryId,String mediaId) => _serialize(fid,() async {
    return _attach(fid,await _load(fid,memoryId),mediaId);
  });
  Future<void> removeMedia(String fid,String memoryId,String mediaId) => _serialize(fid,() async {
    await _removeMedia(await _load(fid,memoryId),mediaId);
  });
  Future<List<_LocatedMemory>> _visible(String fid) async {
    final rows = <_LocatedMemory>[],seen=<String>{};
    for (final space in await _spaces(fid)) {
      for (final row in await store.list(space,_collection(space))) {
        if (!await _validRow(fid,space,row)) continue;
        if (!seen.add(row['id'] as String)) _error(409,'可见空间存在记录标识冲突');
        rows.add((space:space,row:row));
      }
    }
    rows.sort((a,b)=>_compare(b.row,a.row));
    return rows;
  }
  static int _compare(Json a,Json b) {
    final date=(a['event_date'] as String).compareTo(b['event_date'] as String);
    if (date!=0) return date;
    final created=DateTime.parse(a['created_at'] as String).compareTo(DateTime.parse(b['created_at'] as String));
    return created!=0?created:(a['id'] as String).compareTo(b['id'] as String);
  }
  Future<List<Json>> visibleSnapshot(String fid) async => [for(final found in await _visible(fid))await _read(fid,found)];
  /// 旅行等目标资料的投影必须兼容来源权限，不能因操作者看得到就写入全家。
  Future<Json?> referenceForSpace(String fid,String id,String destinationSpace) async {
    final spaces=await _spaces(fid);
    if(!spaces.contains(destinationSpace))return null;
    final found=await _find(fid,id,spaces:spaces);
    if(found==null)return null;
    if(found.space!=destinationSpace&&found.row['visibility']!='family')return null;
    return _read(fid,found);
  }
  Future<Json?> visibleMemory(String fid,String id) async {
    final found=await _find(fid,id);
    if(found==null)return null;
    return _read(fid,found);
  }
  Future<LocalResult> _page(String fid,Json query) async {
    _only(query,{'limit','cursor'});
    var limit=20;
    if (query.containsKey('limit')) {
      final raw=query['limit'];final parsed=raw is int?raw:raw is String?int.tryParse(raw):null;
      if(parsed==null||parsed<1||parsed>50) _error(400,'每页数量须为1至50');limit=parsed;
    }
    final spaces=await _spaces(fid),all=await _visible(fid);
    Json? anchor;
    if(query['cursor']!=null){
      final token=query['cursor'];if(token is! String||token.length>4096) _error(400,'游标无效');
      try {
        final value=jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(token))));
        if(value is! Map) _error(400,'游标无效');
        final cursor=Map<String,dynamic>.from(value);
        _only(cursor,{'version','family','viewer','spaces','event_date','created_at','id'});
        if(cursor['version']!=1||cursor['family']!=fid||cursor['viewer']!=store.deviceId||jsonEncode(cursor['spaces'])!=jsonEncode(spaces)) _error(400,'游标不属于当前权限范围，请刷新');
        _date(cursor['event_date']);
        if(cursor['created_at'] is! String||DateTime.tryParse(cursor['created_at'] as String)==null||cursor['id'] is! String) _error(400,'游标无效');
        _identifier(cursor['id'] as String);anchor=cursor;
      } on FormatException {_error(400,'游标无效');}
      on TypeError {_error(400,'游标无效');}
    }
    final remaining=all.where((found)=>anchor==null||_compare(found.row,anchor!)<0).toList();
    final selected=remaining.take(limit).toList();String? next;
    if(remaining.length>limit){
      final row=selected.last.row;
      next=base64Url.encode(utf8.encode(jsonEncode({'version':1,'family':fid,'viewer':store.deviceId,'spaces':spaces,'event_date':row['event_date'],'created_at':row['created_at'],'id':row['id']})));
    }
    return (data:[for(final found in selected)await _read(fid,found)],meta:{'cursor':next,'total':all.length,'limit':limit});
  }
}
