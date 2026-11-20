import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../../services/external_services.dart';
import '../backup/backup_models.dart';
import '../local_backend.dart';
import '../local_media_repository.dart';
import '../local_store.dart';
import 'memory_routes.dart';

/// 此计划只活在当前进程；每次远程尝试均需新计划与逐次确认，不写入业务日志。
class TravelGenerationPlan {
  TravelGenerationPlan._({required this.familyId,required this.tripId,required this.mediaId,
    required this.endpoint,required this.retentionNotice,required this.modelLabel,
    required this.prompt,required this.image,required this.createdAt,required this.fingerprint});
  final String familyId,tripId,mediaId,retentionNotice,modelLabel,prompt,fingerprint;
  final Uri endpoint;
  final PreparedModelImage image;
  final DateTime createdAt;
  bool _used=false;
}

typedef TravelThumbnailEncoder=Future<Uint8List> Function(Uint8List bytes);

/// 旅行事实、来源引用和生成结果均在本机；对外只调用显式注入的图片服务。
class TravelRoutes {
  TravelRoutes(this.store,{required this.media,required this.memories,this.imageClient,
    DateTime Function()? now,TravelThumbnailEncoder? encodeThumbnail})
    : now=now??DateTime.now,encodeThumbnail=encodeThumbnail??_encodeThumbnail;
  final LocalStore store;
  final LocalMediaRepository media;
  final MemoryRoutes memories;
  final ConfiguredImageClient? imageClient;
  final DateTime Function() now;
  final TravelThumbnailEncoder encodeThumbnail;
  static const _uuid=Uuid();
  static final _ids=RegExp(r'^[A-Za-z0-9_-]{1,100}$');
  static final _sha=RegExp(r'^[a-f0-9]{64}$');
  static const syncFields=<String,Set<String>>{
    'plugins/travel/trips':{'family_id','created_by','created_at','city_name','city_lng','city_lat','place','caption',
      'original_media_id','display_media_id','generated_media_id','ai_status','generation_attempt','generation_error','memory_id','updated_at'},
    'plugins/travel/media':{'trip_id','kind','thumbnail_sha256','thumbnail_bytes','width','height','duration_ms','created_by','sort_key'},
    'plugins/travel/artifacts':{'trip_id','kind','created_by','created_at','thumbnail_ready'},
  };
  static const immutableCollections={'plugins/travel/media','plugins/travel/artifacts'};
  static final _queues=Expando<Map<String,Future<void>>>();
  String get _stamp=>now().toUtc().toIso8601String();
  String _col(String fid,String name)=>'/families/$fid/plugins/travel/$name';
  Directory get _artifacts=>Directory('${media.directory.path}/travel-artifacts-v1');
  static bool _full(RegExp p,String value){final m=p.firstMatch(value);return m!=null&&m.start==0&&m.end==value.length;}
  static Never _fail(int status,String message)=>throw ApiException(
    switch(status){403=>'FORBIDDEN',404=>'NOT_FOUND',405=>'METHOD_NOT_ALLOWED',409=>'CONFLICT',501=>'FEATURE_UNAVAILABLE',503=>'SERVICE_UNAVAILABLE',_=>'VALIDATION_ERROR'},message,statusCode:status);
  static void _only(Json value,Set<String> allowed){if(value.keys.any((k)=>!allowed.contains(k)))_fail(400,'包含未知或只读字段');}
  static String _id(Object? value){if(value is! String||!_full(_ids,value))_fail(400,'标识无效');return value;}
  static String _text(Object? value,int max){if(value is! String||value.trim().isEmpty||value.runes.length>max)_fail(400,'文本为空或过长');return value.trim();}
  static String? _optional(Object? value,int max){if(value==null)return null;if(value is! String||value.runes.length>max)_fail(400,'文本过长');return value.trim().isEmpty?null:value.trim();}
  static num _coordinate(Object? value,int min,int max){if(value is! num||!value.isFinite||value<min||value>max)_fail(400,'城市坐标无效');return value;}
  Future<void> _member(String fid)async{
    _id(fid);final row=await store.get(fid,'/families/$fid/members',store.deviceId);
    if(row==null||row['family_id']!=fid||row['user_id']!=store.deviceId||row['status']!='active')_fail(403,'当前本机身份不是有效家庭成员');
  }
  Future<T> _serial<T>(String fid,Future<T> Function() action){
    final queues=_queues[store]??=<String,Future<void>>{},done=Completer<T>();
    queues[fid]=(queues[fid]??Future<void>.value()).then((_)async{try{done.complete(await action());}catch(e,s){done.completeError(e,s);}});
    return done.future;
  }
  Future<Json> _trip(String fid,String id)async{
    _id(id);final row=await store.get(fid,_col(fid,'trips'),id);
    if(row==null||row['family_id']!=fid)_fail(404,'旅行记录不存在');return row;
  }
  Future<LocalResult?> request(String method,String fid,List<String> tail,{Json body=const{},Json query=const{}})async{
    if(tail.length<2||tail[0]!='travel'||tail[1]!='trips'||tail.length>4||
      tail.length==4&&!{'memory','retry','image'}.contains(tail[3]))return null;
    await _member(fid);_only(query,<String>{});final verb=method.toUpperCase();
    if(verb=='GET'){
      if(tail.length==2)return(data:await snapshot(fid),meta:null);
      if(tail.length==3)return(data:await _read(fid,await _trip(fid,tail[2])),meta:null);
      _fail(501,'本地旅行图片由已核权的本机文件读取，不使用远程 image 端点');
    }
    return _serial(fid,()async{
      await _member(fid);
      if(tail.length==2&&verb=='POST')return(data:await _create(fid,body),meta:null);
      if(tail.length==3&&verb=='DELETE'){
        _only(body,<String>{});final row=await _trip(fid,tail[2]);
        final descriptors=(await store.list(fid,_col(fid,'media'))).where((m)=>m['trip_id']==row['id']);
        final artifacts=(await store.list(fid,_col(fid,'artifacts'))).where((m)=>m['trip_id']==row['id']);
        final changes=<Json>[{'space':fid,'collection':_col(fid,'trips'),'id':row['id'],'fields':<String,dynamic>{},'delete':true},
          for(final d in descriptors){'space':fid,'collection':_col(fid,'media'),'id':d['id'],'fields':<String,dynamic>{},'delete':true},
          for(final a in artifacts){'space':fid,'collection':_col(fid,'artifacts'),'id':a['id'],'fields':<String,dynamic>{},'delete':true}];
        // 来源原件、私有引用和生成文件不随旅行记录删除，避免误删用户资料。
        for(var at=0;at<changes.length;at+=256){await store.batch(changes.sublist(at,at+256>changes.length?changes.length:at+256));}
        return(data:null,meta:null);
      }
      if(tail.length==4&&tail[3]=='memory'&&verb=='PUT'){
        _only(body,{'memory_id'});final row=await _trip(fid,tail[2]);final id=body['memory_id'];
        if(id!=null&&await memories.referenceForSpace(fid,_id(id),fid)==null)_fail(404,'回忆不存在或不能向全家旅行投影');
        await store.patch(fid,_col(fid,'trips'),row['id'] as String,{'memory_id':id,'updated_at':_stamp});
        return(data:await _read(fid,await _trip(fid,row['id'] as String)),meta:null);
      }
      if(tail.length==4&&tail[3]=='retry'&&verb=='POST'){
        _only(body,<String>{});await _trip(fid,tail[2]);
        _fail(409,'每次生成或重试都须先查看发送副本及模型留存政策并明确授权');
      }
      _fail(405,'此本地旅行路由不支持该方法');
    });
  }
  Future<Json> _create(String fid,Json body)async{
    _only(body,{'client_id','media_id','city_name','city_lng','city_lat','place','caption','memory_id'});
    final id=body['client_id']==null?_uuid.v4():_id(body['client_id']);
    final source=_id(body['media_id']);
    final values=<String,dynamic>{'family_id':fid,'city_name':_text(body['city_name'],40),
      'city_lng':_coordinate(body['city_lng'],-180,180),'city_lat':_coordinate(body['city_lat'],-90,90),
      'place':_optional(body['place'],60),'caption':_optional(body['caption'],200),
      'original_media_id':source,'memory_id':body['memory_id']==null?null:_id(body['memory_id'])};
    final fingerprint=LocalStore.canonical(values);
    final existing=await store.get(fid,_col(fid,'trips'),id);
    if(existing!=null){
      if(existing['family_id']!=fid||existing['created_by']!=store.deviceId||await store.privateValue('travel-create:$fid:$id')!=fingerprint)_fail(409,'同一 client_id 对应不同旅行内容');
      return _read(fid,existing);
    }
    if(values['memory_id']!=null&&await memories.referenceForSpace(fid,values['memory_id'] as String,fid)==null)_fail(404,'关联回忆不能向全家旅行投影');
    final descriptor=await _bindOriginal(fid,id,source);
    await store.batch([
      {'space':fid,'collection':_col(fid,'media'),'id':source,'fields':descriptor},
      {'space':fid,'collection':_col(fid,'trips'),'id':id,'fields':{...values,'created_by':store.deviceId,'created_at':_stamp,
        'updated_at':_stamp,'display_media_id':source,'generated_media_id':null,'ai_status':'none','generation_attempt':null,'generation_error':null}},
    ],privateUpdates:{'travel-create:$fid:$id':fingerprint});
    return _read(fid,await _trip(fid,id));
  }
  Future<Json> _bindOriginal(String fid,String tripId,String mediaId)async{
    final ref=await store.deviceReference(mediaId);if(ref==null||ref['kind']!='photo'||ref['locator'] is! String||(ref['locator'] as String).isEmpty)_fail(400,'请选择本机已有授权的原照引用');
    final meta=Json.from(jsonDecode(ref['metadata'] as String) as Map);
    if(meta['memory_id']!=null||meta['scope']!=null&&(meta['scope']!=fid||meta['plugin']!='travel'||meta['trip_id']!=tripId))_fail(403,'已绑定回忆或其它范围的媒体不能转入全家旅行，请重新明确选择');
    if(meta['kind']!='photo'||meta['thumbnail_sha256'] is! String||!_full(_sha,meta['thumbnail_sha256'] as String)||
      meta['thumbnail_bytes'] is! int||meta['thumbnail_bytes']<=0||meta['thumbnail_bytes']>LocalMediaRepository.maxThumbnailBytes)_fail(400,'本机媒体缩略图描述无效');
    final file=await media.thumbnailFile(mediaId);if(file==null)_fail(400,'本机缩略图缺件，请重新选择');
    final bytes=await file.readAsBytes();LocalMediaRepository.validateThumbnail(bytes);
    if(bytes.length!=meta['thumbnail_bytes']||LocalMediaRepository.hash(bytes)!=meta['thumbnail_sha256'])_fail(409,'本机缩略图摘要不符');
    final sortKey='${meta['selected_at']??_stamp}_$mediaId';
    if(meta['sort_key']!=null&&meta['sort_key']!=sortKey)_fail(409,'媒体排序绑定不可改变');
    meta.addAll({'scope':fid,'family_id':fid,'trip_id':tripId,'plugin':'travel','sort_key':sortKey});
    await store.saveDeviceReference(mediaId,'photo',ref['locator'] as String,meta);
    return {'trip_id':tripId,'kind':'photo','thumbnail_sha256':meta['thumbnail_sha256'],'thumbnail_bytes':meta['thumbnail_bytes'],
      'width':meta['width'],'height':meta['height'],'duration_ms':0,'created_by':store.deviceId,'sort_key':sortKey};
  }
  Future<List<Json>> snapshot(String fid)async{
    await _member(fid);final rows=(await store.list(fid,_col(fid,'trips'))).where((r)=>r['family_id']==fid).toList();
    rows.sort((a,b){final t='${b['created_at']}'.compareTo('${a['created_at']}');return t!=0?t:'${a['id']}'.compareTo('${b['id']}');});
    return [for(final row in rows)await _read(fid,row)];
  }
  /// 同步策略须在字段白名单之外再次检查关联的目标权限；不接受受限ID先广播后过滤。
  Future<bool> maySyncTrip(String fid,Json fields)async{
    final id=fields['memory_id'];if(id==null)return true;
    if(id is! String||!_full(_ids,id))return false;
    if(await memories.referenceForSpace(fid,id,fid)!=null)return true;
    // 已删除的全家回忆仍可安全重放历史关联ID；绝不能靠缺失就把受限ID降级成全家。
    final rows=await store.db.query('documents',columns:['data'],where:'space=? AND collection=? AND id=?',
      whereArgs:[fid,'/families/$fid/plugins/memory/memories',id]);
    if(rows.isEmpty)return false;
    final row=Json.from(jsonDecode(rows.single['data'] as String) as Map);
    return row['family_id']==fid&&row['visibility']=='family';
  }
  Future<Json> _read(String fid,Json row)async{
    Json? memory;
    if(row['memory_id'] is String){final visible=await memories.referenceForSpace(fid,row['memory_id'] as String,fid);
      if(visible!=null){final items=(visible['media'] as List?)??[];memory={'id':visible['id'],'title':visible['title'],'event_date':visible['event_date'],
        'cover_url':items.isEmpty?null:(items.first as Map)['url']};}}
    final display=row['display_media_id'];final descriptor=display is String?await store.get(fid,_col(fid,'media'),display):null;
    final imageId=descriptor?['trip_id']==row['id']?display:row['original_media_id'];
    return {'id':row['id'],'family_id':fid,'city_name':row['city_name'],'city_lng':row['city_lng'],'city_lat':row['city_lat'],
      'place':row['place'],'caption':row['caption'],'image_url':'wo-local-travel://$imageId/thumbnail',
      'ai_status':row['ai_status'],'generation_error':row['generation_error'],'created_at':row['created_at'],
      'original_media_id':row['original_media_id'],'generated_media_id':row['generated_media_id'],
      'memory_id':memory?['id'],'memory':memory};
  }
  String _fingerprint(Json trip)=>LocalStore.canonical({'original_media_id':trip['original_media_id'],'place':trip['place']});
  Future<PreparedModelImage> _prepared(String fid,Json row)async{
    final id=_id(row['original_media_id']);final ref=await store.deviceReference(id);
    if(ref==null||ref['kind']!='photo'||ref['locator'] is! String||(ref['locator'] as String).isEmpty)_fail(409,'本机没有此原照的授权引用，不能向模型发送其它手机的媒体');
    final meta=Json.from(jsonDecode(ref['metadata'] as String) as Map);
    if(meta['scope']!=fid||meta['trip_id']!=row['id']||meta['plugin']!='travel')_fail(403,'本机原照不属于此旅行');
    final bytes=await thumbnailBytes(fid,id);if(bytes==null)_fail(409,'本机发送副本缺件');
    // 仅发送用户预览过的去元数据缩略图；不读取原件、句柄或相册ID到HTTP边界。
    return PreparedModelImage(bytes);
  }
  Future<TravelGenerationPlan> planGeneration(String fid,String tripId)async{
    await _member(fid);final row=await _trip(fid,tripId),client=imageClient;
    if(client==null)_fail(503,'尚未配置图片模型，旅行原照和记录已保存在本机');
    ImageModelConfig? config;try{config=await client.loadConfig();}catch(_){_fail(503,'图片模型配置不可用');}
    if(config==null||!config.enabled||config.apiKey.isEmpty||config.model.trim().isEmpty)_fail(503,'尚未配置可调用的图片模型');
    if(config.retentionNotice.trim().isEmpty)_fail(409,'请先填写供应商留存政策并阅读后再授权');
    final image=await _prepared(fid,row);
    return TravelGenerationPlan._(familyId:fid,tripId:tripId,mediaId:row['original_media_id'] as String,
      endpoint:config.baseUrl,retentionNotice:config.retentionNotice,modelLabel:config.model,
      prompt:travelStylePrompt+(row['place']==null?'':'\n地点：${row['place']}'),image:image,createdAt:now(),fingerprint:_fingerprint(row));
  }
  Future<Json> generate(String fid,String tripId,{required TravelGenerationPlan plan,required ImageGenerationConsent consent})=>_serial(fid,()async{
    await _member(fid);var row=await _trip(fid,tripId);
    if(plan._used||plan.familyId!=fid||plan.tripId!=tripId||plan.mediaId!=row['original_media_id']||
      now().difference(plan.createdAt).isNegative||now().difference(plan.createdAt)>const Duration(minutes:10)||
      plan.fingerprint!=_fingerprint(row)||!consent.allowSourceUpload||!consent.providerPolicyReviewed||
      consent.endpoint!=plan.endpoint||consent.retentionNotice!=plan.retentionNotice||consent.expectedModel!=plan.modelLabel)_fail(409,'本次授权已失效或尚未确认，请重新查看发送副本');
    final current=await _prepared(fid,row);
    if(LocalMediaRepository.hash(current.bytes)!=LocalMediaRepository.hash(plan.image.bytes))_fail(409,'发送副本变化，须重新确认');
    final client=imageClient;if(client==null)_fail(503,'图片模型未配置');
    ImageModelConfig? currentConfig;
    try{currentConfig=await client.loadConfig();}catch(_){_fail(503,'图片模型配置不可用');}
    if(currentConfig==null||!currentConfig.enabled||currentConfig.apiKey.isEmpty||
      currentConfig.model!=plan.modelLabel||currentConfig.baseUrl!=plan.endpoint||
      currentConfig.retentionNotice!=plan.retentionNotice)_fail(409,'模型或供应商政策已变化，须重新查看发送副本并授权');
    // client自身也使用expectedModel核对实际加载配置，封闭第二次loadConfig的切换窗口。
    plan._used=true;final attempt=_uuid.v4();
    await store.batch([{'space':fid,'collection':_col(fid,'trips'),'id':tripId,'fields':{'ai_status':'generating','generation_attempt':attempt,'generation_error':null,'updated_at':_stamp}}],
      privateUpdates:{'travel-inflight:$fid:$tripId':attempt});
    try{
      final result=await client.generate(image:plan.image,prompt:plan.prompt,consent:consent);
      await _member(fid);row=await _trip(fid,tripId);
      if(row['generation_attempt']!=attempt||row['original_media_id']!=plan.mediaId)_fail(409,'旅行记录已变化，未覆盖现有结果');
      final artifact=await _storeArtifact(fid,tripId,result,plan:plan,attempt:attempt);
      final artFields=<String,dynamic>{'trip_id':tripId,'kind':'photo','created_by':store.deviceId,'created_at':_stamp,'thumbnail_ready':artifact.thumbnail!=null};
      await store.batch([
        {'space':fid,'collection':_col(fid,'artifacts'),'id':artifact.id,'fields':artFields},
        if(artifact.thumbnail!=null){'space':fid,'collection':_col(fid,'media'),'id':artifact.id,'fields':{
          'trip_id':tripId,'kind':'photo','thumbnail_sha256':LocalMediaRepository.hash(artifact.thumbnail!),
          'thumbnail_bytes':artifact.thumbnail!.length,'width':null,'height':null,'duration_ms':0,
          'created_by':store.deviceId,'sort_key':'${_stamp}_${artifact.id}'}},
        {'space':fid,'collection':_col(fid,'trips'),'id':tripId,'fields':{'generated_media_id':artifact.id,
          if(artifact.thumbnail!=null)'display_media_id':artifact.id,'ai_status':artifact.thumbnail==null?'failed':'ready',
          'generation_error':artifact.thumbnail==null?'preview_unavailable':null,'updated_at':_stamp}},
      ],privateUpdates:{'travel-inflight:$fid:$tripId':null});
    }on ExternalServiceException catch(e){
      // 安全错误码不含供应商正文、密钥、照片或提示词；失败不新建第二条旅行。
      await _recordFailure(fid,tripId,attempt,e.failure.name);
    }catch(e){
      if(e is ApiException)rethrow;
      await _recordFailure(fid,tripId,attempt,'local_result_unavailable');
    }
    return _read(fid,await _trip(fid,tripId));
  });
  Future<void> _recordFailure(String fid,String tripId,String attempt,String code)async{
    await _member(fid);final row=await _trip(fid,tripId);
    if(row['generation_attempt']==attempt)await store.batch([{'space':fid,'collection':_col(fid,'trips'),'id':tripId,'fields':{'ai_status':'failed','generation_error':code,'updated_at':_stamp}}],privateUpdates:{'travel-inflight:$fid:$tripId':null});
  }
  /// 启动后只恢复本机明确记录的中断状态，不重发已可能到达供应商的请求。
  Future<void> recoverInterrupted(String fid)=>_serial(fid,()async{
    await _member(fid);
    for(final row in await store.list(fid,_col(fid,'trips'))){
      final id=row['id'] as String,attempt=await store.privateValue('travel-inflight:$fid:${row['id']}');
      if(attempt==null)continue;
      await store.batch([
        if(row['family_id']==fid&&row['ai_status']=='generating'&&row['generation_attempt']==attempt)
          {'space':fid,'collection':_col(fid,'trips'),'id':id,'fields':{'ai_status':'failed','generation_error':'interrupted','updated_at':_stamp}},
      ],privateUpdates:{'travel-inflight:$fid:$id':null});
    }
  });
  Future<({String id,Uint8List? thumbnail})> _storeArtifact(String fid,String tripId,GeneratedImage image,{required TravelGenerationPlan plan,required String attempt})async{
    final id=_uuid.v4(),ext=switch(image.contentType){'image/jpeg'=>'jpg','image/png'=>'png','image/webp'=>'webp',_=>throw const FormatException('生成图片类型无效')};
    await _artifacts.create(recursive:true);
    final path=File('${_artifacts.path}/$id.$ext');await _writeNew(path,image.bytes);
    await store.setPrivate('travel-artifact:$id',{'v':1,'family_id':fid,'trip_id':tripId,'ext':ext,'size':image.bytes.length,'sha256':LocalMediaRepository.hash(image.bytes),'content_type':image.contentType,
      'provenance':{'attempt':attempt,'source_media_id':plan.mediaId,'source_thumbnail_sha256':LocalMediaRepository.hash(plan.image.bytes),
        'model_label':plan.modelLabel,'endpoint':plan.endpoint.toString(),'retention_notice':plan.retentionNotice,'prompt':plan.prompt,'authorized_at':_stamp}});
    Uint8List? thumb;
    try{thumb=await encodeThumbnail(image.bytes);LocalMediaRepository.validateThumbnail(thumb);
      await _writeNew(File('${media.directory.path}/$id.jpg'),thumb);
    }catch(_){thumb=null;}
    return(id:id,thumbnail:thumb);
  }
  static Future<void> _writeNew(File target,Uint8List bytes)async{
    final temp=File('${target.path}.${_uuid.v4()}.tmp');
    try{if(await target.exists())throw const FileSystemException('本地文件已存在');await temp.writeAsBytes(bytes,flush:true);
      if(await target.exists())throw const FileSystemException('本地文件已存在');await temp.rename(target.path);
    }finally{if(await temp.exists())await temp.delete();}
  }
  Future<void> _localBinding(String fid,String id,String tripId)async{
    final ref=await store.deviceReference(id);
    if(ref!=null){final meta=Json.from(jsonDecode(ref['metadata'] as String) as Map);
      if(meta['scope']!=fid||meta['trip_id']!=tripId||meta['plugin']!='travel')throw const FormatException('不能使用其它本机媒体的缩略图');}
    final artifact=await store.privateValue('travel-artifact:$id');
    if(artifact!=null&&(artifact is! Map||artifact['family_id']!=fid||artifact['trip_id']!=tripId))throw const FormatException('不能使用其它家庭生成结果');
    final received=await store.privateValue('travel-received:$id');
    if(received!=null&&(received is! Map||received['family_id']!=fid||received['trip_id']!=tripId))throw const FormatException('媒体ID已绑定其它范围');
  }
  Future<Uint8List?> thumbnailBytes(String fid,String id)async{
    await _member(fid);_id(id);final descriptor=await store.get(fid,_col(fid,'media'),id);
    if(descriptor==null||descriptor['trip_id'] is! String)return null;
    await _trip(fid,descriptor['trip_id'] as String);
    await _localBinding(fid,id,descriptor['trip_id'] as String);
    final file=await media.thumbnailFile(id);if(file==null)return null;
    if(await file.length()>LocalMediaRepository.maxThumbnailBytes)throw const ThumbnailUnavailable();
    final bytes=await file.readAsBytes();try{LocalMediaRepository.validateThumbnail(bytes);}on FormatException{throw const ThumbnailUnavailable();}
    if(bytes.length!=descriptor['thumbnail_bytes']||LocalMediaRepository.hash(bytes)!=descriptor['thumbnail_sha256'])throw const ThumbnailUnavailable();return bytes;
  }
  Future<Json?> thumbnailForWire(String fid,String id)async{
    final bytes=await thumbnailBytes(fid,id);if(bytes==null)return null;
    return {'space':fid,'id':id,'sha256':LocalMediaRepository.hash(bytes),'bytes':base64Url.encode(bytes)};
  }
  Future<void> receiveThumbnail(String fid,String id,Uint8List bytes,String digest)=>_serial('thumbnail:$fid:$id',()async{
    await _member(fid);_id(id);LocalMediaRepository.validateThumbnail(bytes);
    final row=await store.get(fid,_col(fid,'media'),id);if(row==null||row['trip_id'] is! String||row['thumbnail_sha256']!=digest||row['thumbnail_bytes']!=bytes.length||LocalMediaRepository.hash(bytes)!=digest)throw const FormatException('旅行缩略图描述或摘要不符');
    await _trip(fid,row['trip_id'] as String);
    await _localBinding(fid,id,row['trip_id'] as String);
    await store.setPrivate('travel-received:$id',{'family_id':fid,'trip_id':row['trip_id']});
    final local=await store.deviceReference(id);
    if(local!=null){final meta=Json.from(jsonDecode(local['metadata'] as String) as Map);if(meta['scope']!=fid||meta['trip_id']!=row['trip_id']||meta['plugin']!='travel')throw const FormatException('不可覆盖其它本机媒体引用');}
    final file=File('${media.directory.path}/$id.jpg');
    if(await file.exists()){
      if(await file.length()<=LocalMediaRepository.maxThumbnailBytes&&LocalMediaRepository.hash(await file.readAsBytes())==digest)return;
      await file.rename('${file.path}.corrupt-${_uuid.v4()}');
    }
    await _writeNew(file,bytes);
  });
  Future<File?> displayFile(String fid,String tripId)async{
    await _member(fid);final trip=await _trip(fid,tripId),id=trip['display_media_id'];
    if(id is! String||await thumbnailBytes(fid,id)==null)return null;return media.thumbnailFile(id);
  }
  Future<bool> openOriginal(String fid,String tripId)async{
    await _member(fid);final trip=await _trip(fid,tripId);return media.openOriginal(_id(trip['original_media_id']));
  }
  Future<BackupSource> generatedBackupSource(String fid,String id,{BackupPrivacy privacy=BackupPrivacy.public})async{
    await _member(fid);_id(id);final row=await store.get(fid,_col(fid,'artifacts'),id);
    if(row==null||row['trip_id'] is! String)_fail(404,'生成结果不存在');await _trip(fid,row['trip_id'] as String);
    final raw=await store.privateValue('travel-artifact:$id');
    if(raw is! Map||raw['v']!=1||raw['family_id']!=fid||raw['trip_id']!=row['trip_id']||!{'jpg','png','webp'}.contains(raw['ext']))return _TravelFileSource.missing(id,'photo',privacy);
    final file=File('${_artifacts.path}/$id.${raw['ext']}');
    if(!await file.exists()||await file.length()!=raw['size'])return _TravelFileSource.missing(id,'photo',privacy);
    final digest=await hashing.sha256.bind(file.openRead()).first;
    if(digest.toString()!=raw['sha256'])throw const FormatException('本地生成原件摘要不符');
    return _TravelFileSource(BackupEntry(id:id,kind:'photo',size:await file.length(),sha256:raw['sha256'] as String,sourceExact:true),privacy,file);
  }
  static Future<Uint8List> _encodeThumbnail(Uint8List bytes)async{
    // 原件不变；只对新生成的展示副本重编码，JPEG完整段清理后再验≤512/96KiB。
    for(final side in [256,128,64,32,16,8,4,2,1]){
      final fresh=await FlutterImageCompress.compressWithList(bytes,minWidth:side,minHeight:side,quality:70,format:CompressFormat.jpeg,keepExif:false);
      final clean=_stripFreshJpeg(Uint8List.fromList(fresh));
      try{LocalMediaRepository.validateThumbnail(clean);return clean;}on FormatException{/* 更小的派生副本继续尝试；不触碰原件。 */}
    }
    throw const FormatException('无法生成安全的小缩略图');
  }
  static Uint8List _stripFreshJpeg(Uint8List bytes){
    if(bytes.length<4||bytes.length>20*1024*1024||bytes[0]!=255||bytes[1]!=216)throw const FormatException('JPEG无效');
    final out=BytesBuilder(copy:false)..add(bytes.sublist(0,2));var pos=2,scan=false;
    while(pos<bytes.length){
      var begin=pos;
      if(scan){
        while(pos<bytes.length){if(bytes[pos++]!=255)continue;final markerAt=pos-1;
          while(pos<bytes.length&&bytes[pos]==255){pos++;}if(pos>=bytes.length)throw const FormatException('JPEG截断');
          final marker=bytes[pos++];if(marker==0||marker>=208&&marker<=215||marker==1)continue;
          out.add(bytes.sublist(begin,markerAt));pos=markerAt;scan=false;break;
        }
        if(scan)throw const FormatException('JPEG无结束标记');begin=pos;
      }
      if(bytes[pos++]!=255)throw const FormatException('JPEG段无效');
      while(pos<bytes.length&&bytes[pos]==255){pos++;}if(pos>=bytes.length)throw const FormatException('JPEG截断');
      final marker=bytes[pos++];
      if(marker==217){if(pos!=bytes.length)throw const FormatException('JPEG尾随数据');out.add(bytes.sublist(begin,pos));return out.takeBytes();}
      if(marker==0||marker==216||marker>=208&&marker<=215||pos+2>bytes.length)throw const FormatException('JPEG段无效');
      if(marker==1){out.add(bytes.sublist(begin,pos));continue;}
      final length=(bytes[pos]<<8)|bytes[pos+1];if(length<2||pos+length>bytes.length)throw const FormatException('JPEG段长度无效');
      pos+=length;if(!(marker>=225&&marker<=239||marker==254))out.add(bytes.sublist(begin,pos));
      if(marker==218)scan=true;
    }
    throw const FormatException('JPEG无结束标记');
  }
}

class _TravelFileSource extends BackupSource {
  _TravelFileSource(this.entry,this.privacy,this.file);
  factory _TravelFileSource.missing(String id,String kind,BackupPrivacy privacy)=>_TravelFileSource(
    BackupEntry(id:id,kind:kind,size:0,sha256:'',sourceExact:false,missing:'source_unavailable'),privacy,null);
  @override final BackupEntry entry;
  @override final BackupPrivacy privacy;
  final File? file;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async{
    if(file==null||offset<0||length<0||offset+length>entry.size||await file!.length()!=entry.size)throw const BackupException('source_unavailable');
    return file!.openRead(offset,offset+length);
  }
}

const travelStylePrompt = "请把我上传的照片生成一张 Color Walk 风格旅行记录拼图。这张图的目标是：上半部分展示“由照片转译而来的套色章设计”，下半部分展示“原照片来源”。整体像一页干净、克制、有留白的旅行手账/色彩漫游记录 /文创作品展示页。画面结构，整张图采用竖版拼图，比例接近 4:5 或 3:4。画面分为上下两部分，高度比例固定为1:1：•上半部分是设计展示区。•下半部分是原照片展示区。上半部分使用从照片中提取的柔和低饱和背景色，例如雾绿、灰蓝、米黄、淡粉、浅青或暖灰。在上半部分居中放置一张套色章设计图，印章尺寸不要过大，占上半部分设计区面积不超过30%，周围保留充足留白。文字放在上半部分内部，位于套色章下方或附近，作为设计氛围的一部分。英文短语应根据照片画面和情绪自动生成，不要固定套用同一句。下半部分展示原始照片，可以轻微裁切以适配版式，但必须保留照片主体和最有代表性的场景。套色章设计请先从照片中提取最有识别度的主体，例如建筑、桥、村落、山水、石林、水面、道路、植物或牌匾。然后把它重新设计成一张成熟的旅游文创套色章：•像直接盖印在上半部分设计区里的图案，而不是一张贴上去的邮票。•可以有白色或米白色留白，但不要做成厚纸片、贴纸边、投影卡片或邮票质感。•清晰边框，可用圆角矩形、八角框、花窗框或横版风景框。•使用3 到 5 个专色叠印。•用平面色块、手绘线描、留白和少量装饰纹理表现主体。•颜色应有明确分层，例如水面、岩石、树木、建筑、线条分别使用不同专色。•有轻微印泥颗粒、手工边缘、墨色不均和套印错位感，呈现真实盖章/拓印效果。•整体精致、干净，像可以用于明信片、手账贴纸或景区纪念章的设计。套色章不是照片滤镜，也不是邮票贴片，而是照片内容的图形化盖印转译。文字在设计展示区加入一句根据照片意境生成的简短英文，例如：• Color Walk• Recording one's life• Travel Stamp Study文字要清晰可读，有轻复古、手写、打字机或文创手账气质。文字不需要解释画面，只负责营造记录感和节奏感。如果照片中已有明显文字，不要重复堆叠大标题。如果地点不确定，不要编造地名。鏊体气质画面应当：•干净。克制。有留白。有旅行记录感。有设计作品展示感。•上方设计和下方照片形成清楚的“转译前后对照”。避免做成商业海报、复杂拼贴、信息说明图或普通照片滤镜。";
