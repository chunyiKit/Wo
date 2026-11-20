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
    if(tail.length<2||tail[0]!='movie')return null;
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
}
