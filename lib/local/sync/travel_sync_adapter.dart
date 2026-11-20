import 'dart:convert';
import 'dart:typed_data';

import '../backup/backup_models.dart';
import '../local_media_repository.dart';
import '../local_store.dart';
import '../plugins/travel_routes.dart';
import 'strict_json.dart';

/// 返回当前或整包最终shadow；tombstone保留旧字段，并加保留键 _deleted:true。
/// 这个键不属于业务payload，也不能写回documents/operations。
typedef TravelDocumentLookup=Future<Json?> Function(String scope,String collection,String id);

/// 同步策略的旅行扩展；原件只由已持有全局备份reservation的调用方枚举。
class TravelSyncAdapter {
  TravelSyncAdapter(this.routes);
  final TravelRoutes routes;
  LocalStore get store=>routes.store;
  String _col(String scope,String kind)=>'/families/$scope/plugins/travel/$kind';
  static final _idPattern=RegExp(r'^[A-Za-z0-9_-]{1,100}$');
  static final _shaPattern=RegExp(r'^[a-f0-9]{64}$');
  static bool _full(RegExp p,String value){final m=p.firstMatch(value);return m!=null&&m.start==0&&m.end==value.length;}
  static bool _id(Object? value)=>value is String&&_full(_idPattern,value)&&validBackupId(value);
  static bool _sha(Object? value)=>value is String&&_full(_shaPattern,value);
  static Never _bad()=>throw const FormatException('旅行同步字段、父记录或本机媒体绑定无效');
  static void _scope(String scope){if(!_id(scope)||scope.startsWith('p_')||scope.startsWith('c_'))_bad();}
  static Json _data(Json value)=>{for(final e in value.entries)if(e.key!='id'&&e.key!='_deleted')e.key:e.value};
  static bool _date(Object? value)=>value is String&&value.length<=40&&DateTime.tryParse(value)!=null;
  static bool _text(Object? value,int max,{bool nullable=false,bool empty=false})=>nullable&&value==null||value is String&&value.runes.length<=max&&(empty||value.trim().isNotEmpty);
  Future<Json?> lookup(String scope,String collection,String id)async{
    final rows=await store.db.query('documents',columns:['data','deleted'],where:'space=? AND collection=? AND id=?',whereArgs:[scope,collection,id]);
    if(rows.isEmpty)return null;final row=rows.single;
    return {'id':id,...Json.from(decodeStrictJson(row['data'] as String) as Map),'_deleted':row['deleted']==1};
  }
  static void _fields(String kind,Json fields){
    final allowed=TravelRoutes.syncFields['plugins/travel/$kind'];if(allowed==null||fields.keys.any((k)=>!allowed.contains(k)))_bad();
    for(final e in fields.entries){
      final key=e.key,value=e.value;
      switch(key){
        case 'family_id':case 'created_by':case 'trip_id':case 'original_media_id':case 'display_media_id':
          if(!_id(value))_bad();
        case 'generated_media_id':case 'memory_id':case 'generation_attempt':
          if(value!=null&&!_id(value))_bad();
        case 'created_at':case 'updated_at':if(!_date(value))_bad();
        case 'city_name':if(!_text(value,40))_bad();
        case 'place':if(!_text(value,60,nullable:true))_bad();
        case 'caption':if(!_text(value,200,nullable:true))_bad();
        case 'city_lng':if(value is! num||!value.isFinite||value< -180||value>180)_bad();
        case 'city_lat':if(value is! num||!value.isFinite||value< -90||value>90)_bad();
        case 'ai_status':if(!{'none','generating','ready','failed'}.contains(value))_bad();
        case 'generation_error':
          if(value!=null&&!{'notConfigured','locationDenied','invalidInput','consentRequired','network','remoteStatus','invalidResponse','preview_unavailable','local_result_unavailable','interrupted'}.contains(value))_bad();
        case 'kind':if(value!='photo')_bad();
        case 'thumbnail_sha256':if(!_sha(value))_bad();
        case 'thumbnail_bytes':if(value is! int||value<1||value>LocalMediaRepository.maxThumbnailBytes)_bad();
        case 'width':case 'height':if(value!=null&&(value is! int||value<0||value>100000))_bad();
        case 'duration_ms':if(value is! int||value!=0)_bad();
        case 'sort_key':if(!_text(value,160))_bad();
        case 'thumbnail_ready':if(value is! bool)_bad();
        default:_bad();
      }
    }
  }
  static void _required(String kind,Json row){
    final required=switch(kind){
      'trips'=>{'family_id','created_by','created_at','city_name','city_lng','city_lat','original_media_id','display_media_id','ai_status','updated_at'},
      'media'=>{'trip_id','kind','thumbnail_sha256','thumbnail_bytes','duration_ms','created_by','sort_key'},
      'artifacts'=>{'trip_id','kind','created_by','created_at','thumbnail_ready'},
      _=>throw const FormatException('旅行collection无效')};
    if(!required.every(row.containsKey))_bad();_fields(kind,_data(row));
  }
  Future<void> _binding(String scope,String id,String tripId)async{
    final ref=await store.deviceReference(id);
    if(ref!=null){final raw=decodeStrictJson(ref['metadata'] as String);if(raw is! Map)_bad();
      if(raw['scope']!=scope||raw['trip_id']!=tripId||raw['plugin']!='travel'||raw['memory_id']!=null)_bad();}
    for(final key in ['travel-artifact:$id','travel-received:$id']){
      final meta=await store.privateValue(key);
      if(meta!=null&&(meta is! Map||meta['family_id']!=scope||meta['trip_id']!=tripId))_bad();
    }
    // 同一磁盘媒体ID不能跨插件或家庭复用，即使对端已经知道别处的缩略图摘要。
    final collisions=await store.db.query('documents',columns:['space','collection','data'],where:'id=? AND (collection LIKE ? OR collection LIKE ?)',
      whereArgs:[id,'/families/%/plugins/memory/media','/families/%/plugins/travel/media']);
    for(final item in collisions){
      if(item['space']!=scope||item['collection']!=_col(scope,'media'))_bad();
      final data=decodeStrictJson(item['data'] as String);if(data is! Map||data['trip_id']!=tripId)_bad();
    }
  }
  Future<Json?> _parent(String scope,String tripId,TravelDocumentLookup read)async{
    final trip=await read(scope,_col(scope,'trips'),tripId);if(trip==null)return null;
    _required('trips',trip);if(trip['family_id']!=scope)_bad();return trip;
  }
  Future<bool> _memoryReference(String scope,Object? memoryId,TravelDocumentLookup read)async{
    if(memoryId==null)return true;if(!_id(memoryId))return false;
    // 仅物理全家空间的family记录能投影；不查询私密/伴侣空间来碰运气。
    final memory=await read(scope,'/families/$scope/plugins/memory/memories',memoryId as String);
    return memory!=null&&memory['family_id']==scope&&memory['visibility']=='family';
  }
  /// fields已先过通用actor/sequence/envelope校验；此处补旅行语义与源绑定。
  Future<void> validateOp(Json op,{required TravelDocumentLookup lookup,Json? previous})async{
    final scope=op['space'],id=op['id'],collection=op['collection'],actor=op['actor'],fields=op['fields'];
    if(scope is! String||id is! String||collection is! String||actor is! String||fields is! Map||!_id(id)||!_id(actor))_bad();
    _scope(scope);final prefix='/families/$scope/plugins/travel/';if(!collection.startsWith(prefix))_bad();
    final kind=collection.substring(prefix.length);if(!{'trips','media','artifacts'}.contains(kind))_bad();
    final changes=Json.from(fields);_fields(kind,changes);
    if(op['kind']=='delete'){if(changes.isNotEmpty)_bad();return;}
    if(op['kind']!='patch')_bad();
    if(changes.containsKey('created_by')&&changes['created_by']!=actor)_bad();
    if(changes.containsKey('family_id')&&changes['family_id']!=scope)_bad();
    final immutable=kind=='trips'?{'family_id','created_by','created_at','original_media_id'}:TravelRoutes.syncFields['plugins/travel/$kind']!;
    if(previous!=null){for(final key in immutable){if(previous.containsKey(key)&&changes.containsKey(key)&&LocalStore.canonical(previous[key])!=LocalStore.canonical(changes[key]))_bad();}}
    final finalRow=await lookup(scope,collection,id);
    final merged=finalRow==null?{'id':id,...?previous,...changes}:finalRow;
    _required(kind,merged);
    if(kind=='trips'){
      if(merged['family_id']!=scope||!await _memoryReference(scope,changes.containsKey('memory_id')?changes['memory_id']:merged['memory_id'],lookup))_bad();
      final original=merged['original_media_id'] as String;
      await _binding(scope,original,id);
      final source=await lookup(scope,_col(scope,'media'),original);
      if(source!=null){_required('media',source);if(source['trip_id']!=id)_bad();}
      return;
    }
    final tripId=merged['trip_id'] as String;await _binding(scope,id,tripId);
    final trip=await _parent(scope,tripId,lookup);
    if(trip==null)return; // 分页可先到孤立descriptor；保持惰性，不展示/备份/发缩略图。
    if(kind=='media'&&trip['original_media_id']!=id){
      final artifact=await lookup(scope,_col(scope,'artifacts'),id);
      if(artifact!=null){_required('artifacts',artifact);if(artifact['trip_id']!=tripId||artifact['thumbnail_ready']!=true)_bad();}
      // 缺artifact暂存惰性；descriptions和validateThumbnail必须有它才能输出。
    }
  }
  Future<Json?> _descriptor(String scope,String id,TravelDocumentLookup read)async{
    final row=await read(scope,_col(scope,'media'),id);if(row==null||row['_deleted']==true)return null;
    _required('media',row);final tripId=row['trip_id'] as String;
    final trip=await _parent(scope,tripId,read);if(trip==null||trip['_deleted']==true)return null;
    if(trip['original_media_id']!=id){
      final artifact=await read(scope,_col(scope,'artifacts'),id);if(artifact==null||artifact['_deleted']==true)return null;
      _required('artifacts',artifact);if(artifact['trip_id']!=tripId||artifact['thumbnail_ready']!=true)return null;
    }
    await _binding(scope,id,tripId);return {'id':id,..._data(row)};
  }
  /// 只枚举当前活跃旅行下实际引用的媒体；不输出孤儿、tombstone或受限空间。
  Future<List<Json>> descriptions(String scope)async{
    _scope(scope);final result=<Json>[];
    for(final row in await store.list(scope,_col(scope,'media'))){final descriptor=await _descriptor(scope,row['id'] as String,lookup);if(descriptor!=null)result.add(descriptor);}
    result.sort((a,b)=>(a['id'] as String).compareTo(b['id'] as String));return result;
  }
  Future<void> validateThumbnail(String scope,String id,String digest,Uint8List bytes,{required TravelDocumentLookup lookup})async{
    _scope(scope);if(!_id(id)||!_sha(digest))_bad();LocalMediaRepository.validateThumbnail(bytes);
    final descriptor=await _descriptor(scope,id,lookup);
    if(descriptor==null||descriptor['thumbnail_sha256']!=digest||descriptor['thumbnail_bytes']!=bytes.length||LocalMediaRepository.hash(bytes)!=digest)_bad();
  }
  Future<Json?> thumbnailForWire(String scope,String id)async{
    _scope(scope);if(await _descriptor(scope,id,lookup)==null)return null;
    final wire=await routes.thumbnailForWire(scope,id);if(wire==null)return null;
    if(wire.keys.toSet().difference({'space','id','sha256','bytes'}).isNotEmpty)_bad();return wire;
  }
  Future<void> receiveThumbnail(String scope,String id,Uint8List bytes,String digest)async{
    await validateThumbnail(scope,id,digest,bytes,lookup:lookup);
    await routes.receiveThumbnail(scope,id,bytes,digest);
  }
  static String thumbnailBackupId(String scope,String id)=>'thumb_${LocalMediaRepository.hash(utf8.encode('$scope|$id')).substring(0,48)}';
  /// 调用者必须已取得全局backup reservation，直到全部source读完才释放。
  Future<List<BackupSource>> backupSources(String scope,{BackupPrivacy privacy=BackupPrivacy.public})async{
    _scope(scope);
    final member=await store.get(scope,'/families/$scope/members',store.deviceId);
    if(member==null||member['family_id']!=scope||member['user_id']!=store.deviceId||member['status']!='active')_bad();
    final sources=<BackupSource>[],seen=<String>{};
    final trips=(await store.list(scope,_col(scope,'trips'))).where((t)=>t['family_id']==scope).toList();
    final active=trips.map((t)=>t['id'] as String).toSet();
    void add(BackupSource source){if(!seen.add(source.entry.id))_bad();sources.add(source);}
    for(final trip in trips){
      _required('trips',trip);final id=trip['original_media_id'] as String;
      try{await _binding(scope,id,trip['id'] as String);
        final descriptor=await _descriptor(scope,id,lookup);
        if(descriptor==null||descriptor['trip_id']!=trip['id']){add(_TravelMissingSource(id,'photo',privacy));continue;}
        add(await routes.media.prepareBackupSource(id,privacy:privacy));
      }catch(_){if(!seen.contains(id))add(_TravelMissingSource(id,'photo',privacy));else rethrow;}
    }
    for(final artifact in await store.list(scope,_col(scope,'artifacts'))){
      if(!active.contains(artifact['trip_id']))continue;
      _required('artifacts',artifact);final id=artifact['id'] as String;
      try{await _binding(scope,id,artifact['trip_id'] as String);add(await routes.generatedBackupSource(scope,id,privacy:privacy));}
      catch(_){if(!seen.contains(id))add(_TravelMissingSource(id,'photo',privacy));else rethrow;}
    }
    for(final descriptor in await descriptions(scope)){
      final id=descriptor['id'] as String,backupId=thumbnailBackupId(scope,id);
      try{final bytes=await routes.thumbnailBytes(scope,id);if(bytes==null){add(_TravelMissingSource(backupId,'thumbnail',privacy));continue;}
        add(_TravelThumbnailSource(backupId,bytes,privacy));
      }catch(_){if(!seen.contains(backupId))add(_TravelMissingSource(backupId,'thumbnail',privacy));else rethrow;}
    }
    return sources;
  }
}
class _TravelMissingSource extends BackupSource {
  _TravelMissingSource(String id,String kind,this.privacy):entry=BackupEntry(id:id,kind:kind,size:0,sha256:'',sourceExact:false,missing:'source_unavailable');
  @override final BackupEntry entry;
  @override final BackupPrivacy privacy;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async=>throw const BackupException('source_unavailable');
}
class _TravelThumbnailSource extends BackupSource {
  _TravelThumbnailSource(String id,Uint8List bytes,this.privacy):_bytes=Uint8List.fromList(bytes),entry=BackupEntry(id:id,kind:'thumbnail',size:bytes.length,sha256:LocalMediaRepository.hash(bytes),sourceExact:false);
  final Uint8List _bytes;
  @override final BackupEntry entry;
  @override final BackupPrivacy privacy;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async{
    if(offset<0||length<0||offset+length>_bytes.length)throw const BackupException('invalid_source_range');
    return Stream<List<int>>.value(_bytes.sublist(offset,offset+length));
  }
}
