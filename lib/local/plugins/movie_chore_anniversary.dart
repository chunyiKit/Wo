import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../../services/external_services.dart';
import '../local_backend.dart';
import '../local_store.dart';

/// 片单事实始终本地；外部片库仅通过显式注入的只读查询客户端访问。
class MovieChoreAnniversaryRoutes {
  MovieChoreAnniversaryRoutes(this.store,{this.catalogue,DateTime Function()? now})
      : _now=now??DateTime.now;
  final LocalStore store;
  final MovieCatalogueClient? catalogue;
  final DateTime Function() _now;
  /// 仅操作日志字段；头像展示、查询缓存和原件/凭据不在此表。
  static const syncFields=<String,Set<String>>{
    'plugins/movie/movies':{'family_id','created_by','created_at','title','note','watched','watched_at','intro','tmdb_rating','tmdb_id','tmdb_media_type','ai_status','poster_pending'},
    'plugins/chore/chores':{'family_id','created_by','created_at','title','note','emoji','assigned_to','done','recurring','completed_at'},
    'plugins/anniversary/dates':{'family_id','created_by','created_at','name','event_date','emoji','is_lunar','note','notify_enabled','notify_days_before'},
    'notifications':{'type','title','body','icon_emoji','created_by','created_at','read_by','status','recipient_ids','source_plugin','source_id','source_occurrence'},
  };
  static const _uuid=Uuid();
  static final _id=RegExp(r'^[A-Za-z0-9_-]{1,100}$');
  static final _poster=RegExp(r'^/[a-zA-Z0-9_-]+\.(jpg|jpeg|png|webp)$',caseSensitive:false);
  static final _queues=Expando<Map<String,Future<void>>>();
  String get _stamp=>_now().toUtc().toIso8601String();
  String _col(String fid,String plugin,String name)=>'/families/$fid/plugins/$plugin/$name';
  static Never _fail(int status,String message)=>throw ApiException(
    switch(status){403=>'FORBIDDEN',404=>'NOT_FOUND',405=>'METHOD_NOT_ALLOWED',409=>'CONFLICT',501=>'FEATURE_UNAVAILABLE',502=>'SERVICE_UNAVAILABLE',503=>'SERVICE_UNAVAILABLE',_=>'VALIDATION_ERROR'},message,statusCode:status);
  static void _only(Json value,Set<String> keys){if(value.keys.any((key)=>!keys.contains(key)))_fail(400,'包含未知或只读字段');}
  static void _identifier(String id){if(!_id.hasMatch(id))_fail(400,'标识无效');}
  static String _text(Object? value,int max,String name){
    if(value is! String||value.trim().isEmpty||value.runes.length>max)_fail(400,'$name 为空或超过长度限制');return value.trim();
  }
  static String? _optional(Object? value,int max,String name){
    if(value==null)return null;if(value is! String||value.runes.length>max)_fail(400,'$name 无效或过长');return value.trim().isEmpty?null:value.trim();
  }
  static bool _bool(Object? value){if(value is! bool)_fail(400,'开关必须为 true/false');return value;}
  static bool? _filter(Object? value){
    if(value==null)return null;if(value is bool)return value;
    if(value is String&&['true','false'].contains(value.toLowerCase()))return value.toLowerCase()=='true';
    _fail(400,'筛选开关无效');
  }
  static int _integer(Object? value,int min,int max,String label){
    final parsed=value is int?value:value is String?int.tryParse(value):null;
    if(parsed==null||parsed<min||parsed>max)_fail(400,'$label 超出范围');return parsed;
  }
  static String _clip(String text,int max)=>String.fromCharCodes(text.runes.take(max));
  Future<Json> _member(String fid,[String? userId])async{
    _identifier(fid);final id=userId??store.deviceId;_identifier(id);
    final member=await store.get(fid,'/families/$fid/members',id);
    if(member==null||member['status']!='active'||member['family_id']!=fid||member['user_id']!=id)_fail(userId==null?403:400,userId==null?'本机没有有效家庭成员身份':'指派成员不在此家庭');
    return member;
  }
  Future<Json?> _author(String fid,Object? id)async{
    if(id is! String||!_id.hasMatch(id))return null;
    final m=await store.get(fid,'/families/$fid/members',id);
    return m!=null&&m['status']=='active'&&m['user_id']==id&&m['family_id']==fid?m:null;
  }
  Future<T> _serial<T>(String fid,Future<T> Function() action){
    final queues=_queues[store]??=<String,Future<void>>{};final done=Completer<T>();
    queues[fid]=(queues[fid]??Future<void>.value()).then((_)async{try{done.complete(await action());}catch(e,s){done.completeError(e,s);}});return done.future;
  }
  Future<Json> _load(String fid,String plugin,String collection,String id)async{
    _identifier(id);final row=await store.get(fid,_col(fid,plugin,collection),id);
    if(row==null||row['family_id']!=fid)_fail(404,'记录不存在');return row;
  }
  Future<LocalResult?> request(String method,String fid,List<String> tail,{Json body=const{},Json query=const{}})async{
    if(tail.length<2)return null;
    if(tail[0]=='anniversary'){
      if(tail[1]!='dates'||!([2,3].contains(tail.length)))return null;
      await _member(fid);final verb=method.toUpperCase();
      if(verb=='GET')return _anniversary(verb,fid,tail,body,query);
      return _serial(fid,()=>_anniversary(verb,fid,tail,body,query));
    }
    if(tail[0]=='chore'){
      final known=tail[1]=='chores'&&(tail.length==2||tail.length==3||(tail.length==4&&['complete','reopen','remind'].contains(tail[3])));
      if(!known)return null;
      await _member(fid);final verb=method.toUpperCase();
      if(verb=='GET')return _chore(verb,fid,tail,body,query);
      return _serial(fid,()=>_chore(verb,fid,tail,body,query));
    }
    if(tail[0]!='movie')return null;
    final known=(tail[1]=='movies'&&(tail.length==2||tail.length==3||(tail.length==4&&['enrich','poster'].contains(tail[3]))))||
      (tail[1]=='discover'&&(tail.length==2||(tail.length==3&&['genres','poster'].contains(tail[2]))));
    if(!known)return null;
    await _member(fid);final verb=method.toUpperCase();
    if(verb=='GET')return _movie(verb,fid,tail,body,query);
    return _serial(fid,()=>_movie(verb,fid,tail,body,query));
  }
  Future<T> _query<T>(Future<T> Function(MovieCatalogueClient client) action)async{
    final client=catalogue;if(client==null)_fail(503,'尚未配置独立的电影查询服务，本地片单仍可使用');
    try{return await action(client);}
    on ExternalServiceException catch(e){_fail(e.failure==ServiceFailure.notConfigured?503:502,'电影查询暂不可用，本地片单仍保留');}
  }
  Future<List<Json>> _movieRows(String fid)async=>[for(final row in await store.list(fid,_col(fid,'movie','movies')))if(row['family_id']==fid)row];
  Future<Json> _movieRead(String fid,Json row)async{
    final author=await _author(fid,row['created_by']);
    return {'id':row['id'],'family_id':fid,'title':row['title'],'note':row['note'],
      'watched':row['watched'],'watched_at':row['watched_at'],'created_at':row['created_at'],'created_by':row['created_by'],
      'intro':row['intro'],'tmdb_rating':row['tmdb_rating'],'tmdb_id':row['tmdb_id'],'tmdb_media_type':row['tmdb_media_type'],
      'ai_status':row['ai_status']??'none','poster_url':null,'poster_pending':row['poster_pending']==true,
      'creator_name':author?['display_name'],'creator_emoji':author?['avatar_emoji'],'creator_avatar_url':author?['avatar_url']};
  }
  Future<Json> _saveMovie(String fid,Json values)async{
    final id=_uuid.v4();await store.patch(fid,_col(fid,'movie','movies'),id,{
      'family_id':fid,'created_by':store.deviceId,'created_at':_stamp,'watched':false,'watched_at':null,
      'intro':null,'tmdb_rating':null,'tmdb_id':null,'tmdb_media_type':null,'ai_status':'none','poster_pending':false,...values,
    });return _movieRead(fid,await _load(fid,'movie','movies',id));
  }
  Future<LocalResult> _movie(String verb,String fid,List<String> tail,Json body,Json query)async{
    if(tail[1]=='discover'){
      if(verb!='GET')_fail(405,'片库只允许显式 GET 查询');
      if(tail.length==2)return _discover(fid,query);
      if(tail[2]=='genres'){_only(query,<String>{});return _genres(fid);}
      _only(query,{'path'});_posterPath(query['path']);
      _fail(501,'海报图像端点尚未接入文件服务；可使用显式 fetchPoster 查询，不会伪称海报已保存');
    }
    _only(query,tail.length==2&&verb=='GET'?{'watched'}:<String>{});
    if(tail.length==2){
      if(verb=='GET'){
        final watched=_filter(query['watched']);final rows=(await _movieRows(fid)).where((m)=>watched==null||m['watched']==watched).toList();
        rows.sort((a,b){final flag=(a['watched']==true?1:0)-(b['watched']==true?1:0);if(flag!=0)return flag;
          final aTime=a['watched']==true?a['watched_at']??a['created_at']:a['created_at'];
          final bTime=b['watched']==true?b['watched_at']??b['created_at']:b['created_at'];
          final time=DateTime.parse(bTime as String).compareTo(DateTime.parse(aTime as String));return time!=0?time:(a['id'] as String).compareTo(b['id'] as String);});
        return(data:[for(final row in rows)await _movieRead(fid,row)],meta:null);
      }
      if(verb!='POST')_fail(405,'片单不支持该方法');
      _only(body,{'title','note'});
      return(data:await _saveMovie(fid,{'title':_text(body['title'],80,'片名'),'note':_optional(body['note'],500,'备注')}),meta:null);
    }
    if(tail.length==3&&tail[2]=='from_tmdb'){
      if(verb!='POST')_fail(405,'选择片库条目需要 POST');
      _only(body,{'tmdb_id'});final tmdb=_integer(body['tmdb_id'],1,2147483647,'电影标识');
      final existing=(await _movieRows(fid)).where((row)=>row['tmdb_id']==tmdb&&row['tmdb_media_type']=='movie').firstOrNull;
      if(existing!=null)return(data:await _movieRead(fid,existing),meta:null);
      final selected=await store.privateValue('movie-selection:$fid:$tmdb');
      if(selected is! Map||selected['tmdb_id']!=tmdb)_fail(409,'请先浏览片库选择电影，缺少已确认的本机资料快照');
      return(data:await _saveMovie(fid,{'title':_text(selected['title'],80,'片名'),'note':null,
        'tmdb_id':tmdb,'tmdb_media_type':'movie','intro':selected['overview'],'tmdb_rating':selected['tmdb_rating'],
        'ai_status':'ready','poster_pending':selected['poster_path']!=null}),meta:null);
    }
    final row=await _load(fid,'movie','movies',tail[2]);
    if(tail.length==4){
      if(tail[3]=='enrich'&&verb=='POST')_fail(501,'尚无按片名或ID的只读补充接口；记录已在本地，不会触发旧后端写入');
      if(tail[3]=='poster'&&verb=='GET')_fail(501,'本机海报文件尚未准备，不会返回旧云片单图片地址');
      _fail(405,'此路由不支持该方法');
    }
    if(verb=='GET')return(data:await _movieRead(fid,row),meta:null);
    if(verb=='DELETE'){
      _only(body,<String>{});await store.patch(fid,_col(fid,'movie','movies'),tail[2],{},delete:true);return(data:null,meta:null);
    }
    if(!['PUT','PATCH'].contains(verb))_fail(405,'片单不支持该方法');
    _only(body,{'title','note','watched'});final values=<String,dynamic>{};
    if(body.containsKey('title'))values['title']=_text(body['title'],80,'片名');
    if(body.containsKey('note'))values['note']=_optional(body['note'],500,'备注');
    if(body.containsKey('watched')){
      final watched=_bool(body['watched']);values['watched']=watched;
      values['watched_at']=watched?row['watched_at']??_stamp:null;
    }
    if(values.isNotEmpty)await store.patch(fid,_col(fid,'movie','movies'),tail[2],values);
    return(data:await _movieRead(fid,await _load(fid,'movie','movies',tail[2])),meta:null);
  }
  static String _posterPath(Object? value){if(value is! String||!_poster.hasMatch(value))_fail(400,'海报路径无效');return value;}
  Future<GeneratedImage> fetchPoster(String fid,String posterPath)async{
    await _member(fid);_posterPath(posterPath);return _query((client)=>client.poster(posterPath));
  }
  Future<LocalResult> _genres(String fid)async{
    List<Json> rows;var cached=false;
    try{rows=await _query((client)=>client.genres());await store.setPrivate('movie-genres:$fid',rows);}
    on ApiException catch(e){
      if(![502,503].contains(e.statusCode))rethrow;final old=await store.privateValue('movie-genres:$fid');
      if(old is! List)rethrow;rows=[for(final row in old)Map<String,dynamic>.from(row as Map)];cached=true;
    }
    return(data:rows,meta:{'source':cached?'local-cache':'service','service_unavailable':cached});
  }
  Future<LocalResult> _discover(String fid,Json query)async{
    _only(query,{'genres','sort','page'});
    final raw=query['genres'];final genreIds=<int>[];
    if(raw!=null){if(raw is! String)_fail(400,'类型筛选必须是逗号分隔的编号');
      for(final token in raw.split(',').where((p)=>p.trim().isNotEmpty)){genreIds.add(_integer(token.trim(),1,2147483647,'类型编号'));}}
    final genres=genreIds.toSet().toList()..sort();
    final sort=query['sort']??'popular';if(sort is! String||!['popular','rating','newest'].contains(sort))_fail(400,'片库排序无效');
    final page=query.containsKey('page')?_integer(query['page'],1,500,'页码'):1;
    final key='movie-discover:$fid:${jsonEncode({'genres':genres,'sort':sort,'page':page})}';
    List<Json> snapshots;var cached=false;
    try{
      final rows=await _query((client)=>client.discover(genreIds:genres,sort:sort,page:page));
      snapshots=[for(final row in rows)_discoverSnapshot(row)];
      await store.setPrivate(key,snapshots);
      for(final row in snapshots){await store.setPrivate('movie-selection:$fid:${row['tmdb_id']}',row);}
    }on ApiException catch(e){
      if(![502,503].contains(e.statusCode))rethrow;final old=await store.privateValue(key);
      if(old is! List)rethrow;snapshots=[for(final row in old)Map<String,dynamic>.from(row as Map)];cached=true;
    }
    final added={for(final row in await _movieRows(fid))if(row['tmdb_id'] is int)row['tmdb_id'] as int};
    return(data:[for(final row in snapshots){...row,'poster_url':null,'poster_pending':row['poster_path']!=null,'already_added':added.contains(row['tmdb_id'])}],meta:{'source':cached?'local-cache':'service','service_unavailable':cached,'poster_files_pending':true});
  }
  Json _discoverSnapshot(Json row){
    final id=_integer(row['tmdb_id'],1,2147483647,'片库编号');
    final title=row['title'];if(title is! String||title.trim().isEmpty)_fail(502,'片库资料无效');
    String? posterPath;final posterUrl=row['poster_url'];
    if(posterUrl is String){final uri=Uri.tryParse(posterUrl);final path=uri?.queryParameters['path'];if(path!=null&&_poster.hasMatch(path))posterPath=path;}
    final rating=row['tmdb_rating'];
    if(rating!=null&&(rating is! num||!rating.isFinite||rating<0||rating>10))_fail(502,'片库评分无效');
    return {'tmdb_id':id,'title':_clip(title.trim(),80),'overview':row['overview'] is String?_clip(row['overview'] as String,1000):null,
      'release_date':row['release_date'] is String?_clip(row['release_date'] as String,32):null,'tmdb_rating':rating,'poster_path':posterPath};
  }
  Future<Json> movieStats(String fid)async{
    await _member(fid);final rows=await _movieRows(fid);final watched=rows.where((m)=>m['watched']==true).length;
    return {'total':rows.length,'watched':watched,'to_watch':rows.length-watched,'by_media_type':{
      for(final type in ['movie','tv','unknown'])type:rows.where((m)=>(m['tmdb_media_type']??'unknown')==type).length,
    }};
  }
  Future<Json> moviePreview(String fid)async{
    final stats=await movieStats(fid);
    return {'primary':stats['to_watch']==0?'片单清空啦':'${stats['to_watch']} 部想看',
      'secondary':'已看 ${stats['watched']} 部','color_token':'movie','emoji':'🎬'};
  }

  Future<List<Json>> _choreRows(String fid)async=>[for(final row in await store.list(fid,_col(fid,'chore','chores')))if(row['family_id']==fid)row];
  Future<Json> _choreRead(String fid,Json row)async{
    final assignee=await _author(fid,row['assigned_to']),creator=await _author(fid,row['created_by']);
    return {'id':row['id'],'family_id':fid,'title':row['title'],'note':row['note'],'emoji':row['emoji'],
      'assigned_to':row['assigned_to'],'done':row['done'],'recurring':row['recurring'],'completed_at':row['completed_at'],
      'created_at':row['created_at'],'created_by':row['created_by'],
      'assignee_name':assignee?['display_name'],'assignee_emoji':assignee?['avatar_emoji'],'assignee_avatar_url':assignee?['avatar_url'],
      'creator_name':creator?['display_name'],'creator_emoji':creator?['avatar_emoji'],'creator_avatar_url':creator?['avatar_url']};
  }
  Future<Json> _choreValues(String fid,Json body,{required bool create})async{
    _only(body,{'title','note','emoji','assigned_to','recurring',if(!create)'done'});
    final fields=<String,dynamic>{};
    if(create||body.containsKey('title'))fields['title']=_text(body['title'],64,'家务名');
    if(create||body.containsKey('note'))fields['note']=_optional(body['note'],500,'备注');
    if(create||body.containsKey('emoji'))fields['emoji']=_text(body.containsKey('emoji')?body['emoji']:'🧹',16,'图标');
    if(create||body.containsKey('recurring'))fields['recurring']=_bool(body.containsKey('recurring')?body['recurring']:false);
    if(!create&&body.containsKey('done'))fields['done']=_bool(body['done']);
    if(create||body.containsKey('assigned_to')){
      final id=body['assigned_to'];
      if(id!=null){if(id is! String)_fail(400,'负责人标识无效');await _member(fid,id);}
      fields['assigned_to']=id;
    }
    return fields;
  }
  Future<Json> _choreNotification(String fid,Json chore,String type)async{
    final actor=await _member(fid),assignee=chore['assigned_to'];
    if(assignee is! String)_fail(400,'这件家务还没有指派负责人');
    await _member(fid,assignee);
    final actorName=actor['display_name'] is String?_clip(actor['display_name'] as String,80):'家庭成员';
    final title=chore['title'] as String;
    return {'type':type,'title':type=='chore_assigned'?'你被安排了家务：$title':'记得做家务：$title',
      'body':type=='chore_assigned'?'$actorName 把这件家务交给了你':'$actorName 提醒你完成这件家务',
      'icon_emoji':chore['emoji'],'created_by':store.deviceId,'created_at':_stamp,'read_by':<String>[],
      'status':'pending_local_delivery','recipient_ids':[assignee],'source_plugin':'chore','source_id':chore['id']};
  }
  Future<void> _writeChore(String fid,String id,Json fields,{Json? notification})async{
    await store.batch([
      {'space':fid,'collection':_col(fid,'chore','chores'),'id':id,'fields':fields},
      if(notification!=null){'space':fid,'collection':'/families/$fid/notifications','id':_uuid.v4(),'fields':notification},
    ]);
  }
  Future<LocalResult> _chore(String verb,String fid,List<String> tail,Json body,Json query)async{
    _only(query,tail.length==2&&verb=='GET'?{'done'}:<String>{});
    if(tail.length==2){
      if(verb=='GET'){
        final done=_filter(query['done']);final rows=(await _choreRows(fid)).where((row)=>done==null||row['done']==done).toList();
        rows.sort((a,b){final status=(a['done']==true?1:0)-(b['done']==true?1:0);if(status!=0)return status;
          final time=DateTime.parse(b['created_at'] as String).compareTo(DateTime.parse(a['created_at'] as String));return time!=0?time:(a['id'] as String).compareTo(b['id'] as String);});
        return(data:[for(final row in rows)await _choreRead(fid,row)],meta:null);
      }
      if(verb!='POST')_fail(405,'家务不支持该方法');
      final values=await _choreValues(fid,body,create:true),id=_uuid.v4();
      final fields=<String,dynamic>{...values,'family_id':fid,'created_by':store.deviceId,'created_at':_stamp,'done':false,'completed_at':null};
      final shouldNotify=fields['assigned_to']!=null&&fields['assigned_to']!=store.deviceId;
      final notification=shouldNotify?await _choreNotification(fid,{'id':id,...fields},'chore_assigned'):null;
      await _writeChore(fid,id,fields,notification:notification);
      return(data:await _choreRead(fid,await _load(fid,'chore','chores',id)),meta:null);
    }
    if(tail.length==3&&tail[2]=='reset-recurring'){
      if(verb!='POST')_fail(405,'重置重复家务需要 POST');_only(body,<String>{});
      final rows=(await _choreRows(fid)).where((row)=>row['recurring']==true&&row['done']==true).toList();
      for(var start=0;start<rows.length;start+=256){await store.batch([for(final row in rows.skip(start).take(256)){
        'space':fid,'collection':_col(fid,'chore','chores'),'id':row['id'],'fields':{'done':false,'completed_at':null},
      }]);}
      return(data:{'reset':rows.length},meta:null);
    }
    final row=await _load(fid,'chore','chores',tail[2]);
    if(tail.length==4){
      if(verb!='POST')_fail(405,'家务状态操作需要 POST');_only(body,<String>{});
      if(tail[3]=='remind'){
        if(row['done']==true)_fail(400,'这件家务已经完成');
        final notification=await _choreNotification(fid,row,'chore_reminder');
        final requestId=_uuid.v4();await store.patch(fid,'/families/$fid/notifications',requestId,notification);
        return(data:{'reminded':row['assigned_to'],'notification_id':requestId,'status':'pending_local_delivery','system_delivered':false},meta:null);
      }
      final done=tail[3]=='complete';
      if(row['done']!=done)await store.patch(fid,_col(fid,'chore','chores'),tail[2],{'done':done,'completed_at':done?_stamp:null});
      return(data:await _choreRead(fid,await _load(fid,'chore','chores',tail[2])),meta:null);
    }
    if(verb=='GET')return(data:await _choreRead(fid,row),meta:null);
    if(verb=='DELETE'){_only(body,<String>{});await store.patch(fid,_col(fid,'chore','chores'),tail[2],{},delete:true);return(data:null,meta:null);}
    if(!['PUT','PATCH'].contains(verb))_fail(405,'家务不支持该方法');
    final fields=await _choreValues(fid,body,create:false);
    if(fields.containsKey('done'))fields['completed_at']=fields['done']==true?row['completed_at']??_stamp:null;
    final next={...row,...fields};
    final reassigned=fields.containsKey('assigned_to')&&fields['assigned_to']!=row['assigned_to']&&fields['assigned_to']!=null&&fields['assigned_to']!=store.deviceId;
    final notification=reassigned?await _choreNotification(fid,next,'chore_assigned'):null;
    if(fields.isNotEmpty)await _writeChore(fid,tail[2],fields,notification:notification);
    return(data:await _choreRead(fid,await _load(fid,'chore','chores',tail[2])),meta:null);
  }
  Future<Json> choreStats(String fid)async{
    await _member(fid);final rows=await _choreRows(fid),open=rows.where((row)=>row['done']!=true).toList();
    return {'total':rows.length,'open':open.length,'done':rows.length-open.length,'mine_open':open.where((row)=>row['assigned_to']==store.deviceId).length,'recurring_open':open.where((row)=>row['recurring']==true).length};
  }
  Future<Json> chorePreview(String fid)async{
    final stats=await choreStats(fid),mine=stats['mine_open'] as int,total=stats['open'] as int;
    if(mine>0)return {'primary':'$mine 件家务待做','secondary':'该你出手啦','color_token':'chore','secondary_tone':'warning','badge':'$mine','emoji':'🧹'};
    return {'primary':total==0?'家务都做完啦':'你没有待办家务','secondary':total==0?'干净又整齐 ✨':'家里还有 $total 件','color_token':'chore','emoji':'🧹'};
  }

  static String _calendarDate(Object? value){
    if(value is! String||!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value))_fail(400,'日期必须是 YYYY-MM-DD');
    final parsed=DateTime.tryParse(value);if(parsed==null||parsed.year<1||parsed.year>9999)_fail(400,'日期不存在');
    final normalized=[parsed.year.toString().padLeft(4,'0'),parsed.month.toString().padLeft(2,'0'),parsed.day.toString().padLeft(2,'0')].join('-');
    if(value!=normalized)_fail(400,'日期不存在');return value;
  }
  static String _formatDay(DateTime d)=>[d.year.toString().padLeft(4,'0'),d.month.toString().padLeft(2,'0'),d.day.toString().padLeft(2,'0')].join('-');
  DateTime _nextAnniversary(Json row){
    final date=_calendarDate(row['event_date']),lunar=_bool(row['is_lunar']);
    try{return LocalAnniversaryCalendar.nextOccurrence(DateTime.parse(date),_now(),isLunar:lunar);}
    on UnsupportedError{_fail(501,'日期超出当前本地日历支持范围，未改用其他历法');}
  }
  Json _anniversaryValues(Json body,{required bool create}){
    _only(body,{'name','event_date','emoji','is_lunar','note','notify_enabled','notify_days_before'});
    final values=<String,dynamic>{};
    if(create||body.containsKey('name'))values['name']=_text(body['name'],32,'纪念日名称');
    if(create||body.containsKey('event_date'))values['event_date']=_calendarDate(body['event_date']);
    if(create||body.containsKey('emoji'))values['emoji']=_text(body.containsKey('emoji')?body['emoji']:'💞',16,'图标');
    if(create||body.containsKey('note'))values['note']=_optional(body['note'],200,'备注');
    if(create||body.containsKey('is_lunar'))values['is_lunar']=_bool(body.containsKey('is_lunar')?body['is_lunar']:false);
    if(create||body.containsKey('notify_enabled'))values['notify_enabled']=_bool(body.containsKey('notify_enabled')?body['notify_enabled']:false);
    if(create||body.containsKey('notify_days_before'))values['notify_days_before']=_integer(body.containsKey('notify_days_before')?body['notify_days_before']:0,0,365,'提前天数');
    return values;
  }
  Future<List<Json>> _anniversaryRows(String fid)async=>[for(final row in await store.list(fid,_col(fid,'anniversary','dates')))if(row['family_id']==fid)row];
  Future<Json> _anniversaryRead(String fid,Json row)async{
    final next=_nextAnniversary(row),today=_now(),creator=await _author(fid,row['created_by']);
    return {'id':row['id'],'family_id':fid,'name':row['name'],'event_date':row['event_date'],'emoji':row['emoji'],
      'is_lunar':row['is_lunar'],'note':row['note'],'notify_enabled':row['notify_enabled'],'notify_days_before':row['notify_days_before'],
      'days_until':next.difference(DateTime.utc(today.year,today.month,today.day)).inDays,'next_occurrence':_formatDay(next),
      'created_at':row['created_at'],'created_by':row['created_by'],
      'creator_name':creator?['display_name'],'creator_emoji':creator?['avatar_emoji'],'creator_avatar_url':creator?['avatar_url']};
  }
  Future<LocalResult> _anniversary(String verb,String fid,List<String> tail,Json body,Json query)async{
    _only(query,<String>{});
    if(tail.length==2){
      if(verb=='GET'){
        final rows=await _anniversaryRows(fid);rows.sort((a,b){final d=(a['event_date'] as String).compareTo(b['event_date'] as String);return d!=0?d:(a['id'] as String).compareTo(b['id'] as String);});
        return(data:[for(final row in rows)await _anniversaryRead(fid,row)],meta:null);
      }
      if(verb!='POST')_fail(405,'纪念日不支持该方法');
      final fields=_anniversaryValues(body,create:true);_nextAnniversary(fields);
      final id=_uuid.v4();await store.patch(fid,_col(fid,'anniversary','dates'),id,{...fields,'family_id':fid,'created_by':store.deviceId,'created_at':_stamp});
      return(data:await _anniversaryRead(fid,await _load(fid,'anniversary','dates',id)),meta:null);
    }
    final row=await _load(fid,'anniversary','dates',tail[2]);
    if(verb=='GET')return(data:await _anniversaryRead(fid,row),meta:null);
    if(verb=='DELETE'){_only(body,<String>{});await store.patch(fid,_col(fid,'anniversary','dates'),tail[2],{},delete:true);return(data:null,meta:null);}
    if(!['PUT','PATCH'].contains(verb))_fail(405,'纪念日不支持该方法');
    final fields=_anniversaryValues(body,create:false);_nextAnniversary({...row,...fields});
    if(fields.isNotEmpty)await store.patch(fid,_col(fid,'anniversary','dates'),tail[2],fields);
    return(data:await _anniversaryRead(fid,await _load(fid,'anniversary','dates',tail[2])),meta:null);
  }
  Future<Json> anniversaryPreview(String fid,{Json config=const{}})async{
    await _member(fid);final rows=[for(final row in await _anniversaryRows(fid))await _anniversaryRead(fid,row)];
    if(rows.isEmpty)return {'primary':'还没有记录','secondary':'点击添加第一个纪念日','color_token':'anniv'};
    rows.sort((a,b){final days=(a['days_until'] as int).compareTo(b['days_until'] as int);return days!=0?days:(a['id'] as String).compareTo(b['id'] as String);});
    final pinned=config['anniversary_id'];final selected=rows.where((row)=>row['id']==pinned).firstOrNull??rows.first;
    final days=selected['days_until'] as int;
    return {'primary':selected['name'],'secondary':days==0?'就是今天 🎉':'还有 $days 天','color_token':'anniv','emoji':selected['emoji']};
  }
  /// 只生成可持久化的待投递请求；根执行器仍需复核来源、偏好和系统授权。
  Future<int> requestDueAnniversaryReminders(String fid)=>_serial(fid,()async{
    await _member(fid);final members=await store.list(fid,'/families/$fid/members');
    final recipients={for(final m in members)if(m['family_id']==fid&&m['status']=='active'&&m['user_id'] is String&&m['id']==m['user_id'])m['user_id'] as String}.toList()..sort();
    var requested=0;
    for(final row in await _anniversaryRows(fid)){
      if(row['notify_enabled']!=true)continue;
      final next=_nextAnniversary(row),today=_now();
      final delta=next.difference(DateTime.utc(today.year,today.month,today.day)).inDays;
      if(delta<0||delta>(row['notify_days_before'] as int))continue;
      final occurrence=_formatDay(next),sourceId=row['id'] as String;
      final id=_uuid.v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8','anniversary:$fid:$sourceId:$occurrence');
      if(await store.revision(fid,'/families/$fid/notifications',id)>0)continue;
      await store.patch(fid,'/families/$fid/notifications',id,{
        'type':'anniversary_due','title':delta==0?'今天是「${row['name']}」':'「${row['name']}」还有 $delta 天',
        'body':delta==0?'别忘了这个特别的日子 🎉':'记得提前准备哦 🎀','icon_emoji':row['emoji'],
        'created_by':store.deviceId,'created_at':_stamp,'read_by':<String>[],'status':'pending_local_delivery',
        'recipient_ids':recipients,'source_plugin':'anniversary','source_id':sourceId,'source_occurrence':occurrence,
      });requested++;
    }
    return requested;
  });
}

/*
 * Calendar year-size facts adapted from yize/solarlunar const/lunarInfo.js.
 * https://github.com/yize/solarlunar/blob/master/const/lunarInfo.js
 * ISC License
 * Copyright (c) 2015, yize
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */
/// 无运行时外部依赖的月大小/闰月换算；1954/2057/2097月首按香港天文台校正。
/// 日期只取年月日并在 UTC 计算，避免手机时区/DST 把日历天数算错。
class LocalAnniversaryCalendar {
  static const firstYear=1900,lastYear=2099;
  static final _epoch=DateTime.utc(1900,1,31);
  static const _yearInfo=<int>[
    0x04bd8,0x04ae0,0x0a570,0x054d5,0x0d260,0x0d950,0x16554,0x056a0,0x09ad0,0x055d2,
    0x04ae0,0x0a5b6,0x0a4d0,0x0d250,0x1d255,0x0b540,0x0d6a0,0x0ada2,0x095b0,0x14977,
    0x04970,0x0a4b0,0x0b4b5,0x06a50,0x06d40,0x1ab54,0x02b60,0x09570,0x052f2,0x04970,
    0x06566,0x0d4a0,0x0ea50,0x06e95,0x05ad0,0x02b60,0x186e3,0x092e0,0x1c8d7,0x0c950,
    0x0d4a0,0x1d8a6,0x0b550,0x056a0,0x1a5b4,0x025d0,0x092d0,0x0d2b2,0x0a950,0x0b557,
    0x06ca0,0x0b550,0x15355,0x04da0,0x0a5d0,0x14573,0x052b0,0x0a9a8,0x0e950,0x06aa0,
    0x0aea6,0x0ab50,0x04b60,0x0aae4,0x0a570,0x05260,0x0f263,0x0d950,0x05b57,0x056a0,
    0x096d0,0x04dd5,0x04ad0,0x0a4d0,0x0d4d4,0x0d250,0x0d558,0x0b540,0x0b6a0,0x195a6,
    0x095b0,0x049b0,0x0a974,0x0a4b0,0x0b27a,0x06a50,0x06d40,0x0af46,0x0ab60,0x09570,
    0x04af5,0x04970,0x064b0,0x074a3,0x0ea50,0x06b58,0x05ac0,0x0ab60,0x096d5,0x092e0,
    0x0c960,0x0d954,0x0d4a0,0x0da50,0x07552,0x056a0,0x0abb7,0x025d0,0x092d0,0x0cab5,
    0x0a950,0x0b4a0,0x0baa4,0x0ad50,0x055d9,0x04ba0,0x0a5b0,0x15176,0x052b0,0x0a930,
    0x07954,0x06aa0,0x0ad50,0x05b52,0x04b60,0x0a6e6,0x0a4e0,0x0d260,0x0ea65,0x0d530,
    0x05aa0,0x076a3,0x096d0,0x04afb,0x04ad0,0x0a4d0,0x1d0b6,0x0d250,0x0d520,0x0dd45,
    0x0b5a0,0x056d0,0x055b2,0x049b0,0x0a577,0x0a4b0,0x0aa50,0x1b255,0x06d20,0x0ada0,
    0x14b63,0x09370,0x049f8,0x04970,0x064b0,0x168a6,0x0ea50,0x06aa0,0x1a6c4,0x0aae0,
    0x092e0,0x0d2e3,0x0c960,0x0d557,0x0d4a0,0x0da50,0x05d55,0x056a0,0x0a6d0,0x055d4,
    0x052d0,0x0a9b8,0x0a950,0x0b4a0,0x0b6a6,0x0ad50,0x055a0,0x0aba4,0x0a5b0,0x052b0,
    0x0b273,0x06930,0x07337,0x06aa0,0x0ad50,0x14b55,0x04b60,0x0a570,0x054e4,0x0d160,
    0x0e968,0x0d520,0x0daa0,0x16aa6,0x056d0,0x04ae0,0x0a9d4,0x0a2d0,0x0d150,0x0f252,
  ];
  static final _starts=_yearStarts();
  static List<int> _yearStarts(){
    final starts=<int>[0];
    for(var year=firstYear;year<=lastYear;year++){starts.add(starts.last+_months(year).fold<int>(0,(sum,m)=>sum+m.days));}
    return starts;
  }
  static DateTime _day(DateTime value)=>DateTime.utc(value.year,value.month,value.day);
  static Iterable<({int month,bool leap,int days})> _months(int year)sync*{
    final info=_yearInfo[year-firstYear],leap=info&15;
    for(var month=1;month<=12;month++){
      yield(month:month,leap:false,days:29+((info&(0x10000>>month))==0?0:1));
      if(month==leap)yield(month:month,leap:true,days:29+((info&0x10000)==0?0:1));
    }
  }
  static ({int year,int month,int day,bool leap}) fromSolar(DateTime value){
    var offset=_day(value).difference(_epoch).inDays;
    if(offset<0||offset>=_starts.last)throw UnsupportedError('农历转换日期超出1900-01-31至2100-02-08范围');
    var year=firstYear;
    while(offset>=_starts[year-firstYear+1]){year++;}
    offset-=_starts[year-firstYear];
    for(final month in _months(year)){
      if(offset<month.days)return(year:year,month:month.month,day:offset+1,leap:month.leap);
      offset-=month.days;
    }
    throw StateError('农历年表结构不一致');
  }
  static DateTime? toSolar(int year,int month,int day,{bool leap=false}){
    if(year<firstYear||year>lastYear||month<1||month>12||day<1)return null;
    var offset=_starts[year-firstYear];
    for(final entry in _months(year)){
      if(entry.month==month&&entry.leap==leap){
        if(day>entry.days)return null;
        return _epoch.add(Duration(days:offset+day-1));
      }
      offset+=entry.days;
    }
    return null;
  }
  static DateTime nextOccurrence(DateTime eventDate,DateTime today,{bool isLunar=false}){
    final current=_day(today),target=_day(eventDate);
    if(!isLunar){
      // 2月29日只在真实存在的日期发生，不能让 DateTime 静默归一化为3月1日。
      for(var year=current.year;year<=current.year+8&&year<=9999;year++){
        final candidate=DateTime.utc(year,target.month,target.day);
        if(candidate.month!=target.month||candidate.day!=target.day)continue;
        if(!candidate.isBefore(current))return candidate;
      }
      throw UnsupportedError('下次公历日期超出支持范围');
    }
    final original=fromSolar(target),thisLunarYear=fromSolar(current).year;
    // 公历一月仍可能属于前一农历年，不能直接从 Gregorian year 开始。
    for(var year=thisLunarYear;year<=lastYear;year++){
      DateTime? selected;
      for(final leap in original.leap?[true,false]:[false]){
        for(final day in [original.day,original.day-1]){
          selected=toSolar(year,original.month,day,leap:leap);
          if(selected!=null)break;
        }
        if(selected!=null)break;
      }
      if(selected!=null&&!selected.isBefore(current))return selected;
    }
    throw UnsupportedError('下次农历周年超出年表范围，未改用公历');
  }
  static int daysUntil(DateTime eventDate,DateTime today,{bool isLunar=false})=>
    nextOccurrence(eventDate,today,isLunar:isLunar).difference(_day(today)).inDays;
}
