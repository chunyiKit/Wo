import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/local/local_backend.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/movie_chore_anniversary.dart';
import 'package:wo/services/external_services.dart';

void main(){
  sqfliteFfiInit();
  const fid='family-local';
  late Directory directory;
  late LocalStore store;
  late MovieChoreAnniversaryRoutes routes;
  late DateTime clock;
  late List<http.Request> requests;
  late http.Client transport;
  late MovieCatalogueClient catalogue;
  late bool offline;
  Matcher error(int status)=>throwsA(isA<ApiException>().having((e)=>e.statusCode,'status',status));
  Future<void> member(String family,String id)async{
    await store.patch(family,'/families/$family/members',id,{'user_id':id,'family_id':family,'status':'active','role':'member','display_name':'本机成员','avatar_emoji':'🐱','avatar_url':'/local/avatar/$id?v=1'});
  }
  Future<LocalResult> call(String method,List<String> tail,{Json body=const{},Json query=const{},String family=fid})async{
    final result=await routes.request(method,family,['movie',...tail],body:body,query:query);expect(result,isNotNull);return result!;
  }
  Future<Json> create(String title)async=>Map<String,dynamic>.from((await call('POST',['movies'],body:{'title':title})).data as Map);
  setUp(()async{
    directory=await Directory.systemTemp.createTemp('wo-local-movie-');
    store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/local.sqlite');
    await member(fid,store.deviceId);clock=DateTime.utc(2026,11,20,12);requests=[];offline=false;
    transport=MockClient((request)async{
      requests.add(request);expect(request.method,'GET');
      if(offline)throw http.ClientException('synthetic offline');
      if(request.url.path.endsWith('/genres'))return http.Response(jsonEncode({'success':true,'data':[{'id':18,'name':'剧情'},{'id':35,'name':'喜剧'}]}),200);
      if(request.url.path.endsWith('/poster'))return http.Response.bytes([255,216,255,217],200,headers:{'content-type':'image/jpeg'});
      return http.Response(jsonEncode({'success':true,'data':[{
        'tmdb_id':17,'title':'合成片名','overview':'合成简介','release_date':'2026-01-01','tmdb_rating':8.5,
        'poster_url':'/api/v1/families/remote-service-family/plugins/movie/discover/poster?path=%2Fposter.jpg','already_added':true,
      }]}),200);
    });
    catalogue=MovieCatalogueClient(loadConfig:()async=>MovieBackendConfig(baseUrl:Uri.parse('https://movie.invalid'),remoteFamilyId:'remote-service-family',bearerToken:'synthetic-service-token'),client:transport);
    routes=MovieChoreAnniversaryRoutes(store,catalogue:catalogue,now:()=>clock);
  });
  tearDown(()async{transport.close();await store.close();await directory.delete(recursive:true);});

  test('电影手工 CRUD 完全本地且模型/作者真实头像/重启保持',()async{
    final raw=await create(' 本地片名 '),id=raw['id'] as String;
    final movie=Movie.fromJson(raw);expect(movie.title,'本地片名');expect(movie.aiStatus,'none');expect(movie.createdBy,store.deviceId);
    expect(raw['creator_avatar_url'],'/local/avatar/${store.deviceId}?v=1');
    final updated=await call('PUT',['movies',id],body:{'title':'修改片名','note':' 备注 '});expect((updated.data as Map)['note'],'备注');
    await call('PATCH',['movies',id],body:{'note':null});
    await store.close();store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/local.sqlite');
    routes=MovieChoreAnniversaryRoutes(store,now:()=>clock);
    final read=Movie.fromJson(Map<String,dynamic>.from((await call('GET',['movies',id])).data as Map));
    expect(read.title,'修改片名');expect(read.note,isNull);expect(requests,isEmpty);
    expect((await call('DELETE',['movies',id])).data,isNull);await expectLater(call('GET',['movies',id]),error(404));
    expect(await store.get(fid,'/families/$fid/plugins/movie/movies',id),isNull);
  });
  test('已看切换幂等保留原时间，排序筛选和统计从SQLite派生',()async{
    final older=await create('旧');clock=clock.add(const Duration(seconds:1));final newer=await create('新');
    final marked=await call('PUT',['movies',older['id'] as String],body:{'watched':true});
    final first=(marked.data as Map)['watched_at'];clock=clock.add(const Duration(days:1));
    expect(((await call('PUT',['movies',older['id'] as String],body:{'watched':true})).data as Map)['watched_at'],first);
    final list=(await call('GET',['movies'])).data as List;expect(list.map((row)=>(row as Map)['id']),[newer['id'],older['id']]);
    final filtered=(await call('GET',['movies'],query:{'watched':'true'})).data as List;expect(filtered.single['id'],older['id']);
    expect(await routes.movieStats(fid),{'total':2,'watched':1,'to_watch':1,'by_media_type':{'movie':0,'tv':0,'unknown':2}});
    await call('PUT',['movies',older['id'] as String],body:{'watched':false});
    expect(((await call('GET',['movies',older['id'] as String])).data as Map)['watched_at'],isNull);
    expect((await routes.moviePreview(fid))['secondary'],'已看 0 部');expect(requests,isEmpty);
  });
  test('类型/发现只GET服务，选择资料快照只落本地，不向云片单写入',()async{
    final genres=(await call('GET',['discover','genres'])).data as List;expect(MovieGenre.fromJson(Map<String,dynamic>.from(genres.first as Map)).name,'剧情');
    final found=await call('GET',['discover'],query:{'genres':'35,18,18','sort':'rating','page':2});
    final card=DiscoverMovie.fromJson(Map<String,dynamic>.from((found.data as List).single as Map));
    expect(card.alreadyAdded,isFalse);expect(card.posterUrl,isNull);
    expect(requests.last.url.queryParameters,{'genres':'18,35','sort':'rating','page':'2'});
    expect(requests.last.url.path,contains('/families/remote-service-family/'));expect(requests.last.url.toString(),isNot(contains(fid)));
    final before=requests.length;
    final added=await call('POST',['movies','from_tmdb'],body:{'tmdb_id':17});
    final movie=Movie.fromJson(Map<String,dynamic>.from(added.data as Map));expect(movie.title,'合成片名');expect(movie.intro,'合成简介');expect(movie.tmdbRating,8.5);expect(movie.aiStatus,'ready');expect(movie.posterUrl,isNull);
    expect(requests.length,before);
    final repeated=await call('POST',['movies','from_tmdb'],body:{'tmdb_id':17});expect((repeated.data as Map)['id'],movie.id);
    expect((await routes.movieStats(fid))['total'],1);
    final log=LocalStore.canonical(await store.exportSince(fid,{}));
    for(final secret in ['synthetic-service-token','remote-service-family','poster.jpg','movie.invalid']){expect(log,isNot(contains(secret)));}
    expect(requests.every((request)=>request.method=='GET'),isTrue);
  });
  test('already_added即使远程相反也按当前SQLite重算，离线缓存仍可选择',()async{
    final first=await call('GET',['discover']);expect(((first.data as List).single as Map)['already_added'],isFalse);
    offline=true;final cached=await call('GET',['discover']);expect(cached.meta!['source'],'local-cache');expect(cached.meta!['service_unavailable'],isTrue);
    final added=await call('POST',['movies','from_tmdb'],body:{'tmdb_id':17});
    final later=await call('GET',['discover']);expect(((later.data as List).single as Map)['already_added'],isTrue);
    await call('DELETE',['movies',(added.data as Map)['id'] as String]);
    final deleted=await call('GET',['discover']);expect(((deleted.data as List).single as Map)['already_added'],isFalse);
    final readded=await call('POST',['movies','from_tmdb'],body:{'tmdb_id':17});expect((readded.data as Map)['id'],isNot((added.data as Map)['id']));
  });
  test('服务无配置或无缓存只影响查询，缺选择快照明确拒绝',()async{
    routes=MovieChoreAnniversaryRoutes(store,now:()=>clock);
    await expectLater(call('GET',['discover']),error(503));await expectLater(call('GET',['discover','genres']),error(503));
    await expectLater(call('POST',['movies','from_tmdb'],body:{'tmdb_id':999}),error(409));
    await create('仍可保存');expect((await routes.movieStats(fid))['total'],1);expect(requests,isEmpty);
  });
  test('海报仅显式只读查询，旧enrich和文件端点不伪造完成',()async{
    final image=await routes.fetchPoster(fid,'/poster.jpg');expect(image.bytes,[255,216,255,217]);expect(requests.single.method,'GET');
    expect(requests.single.url.path.endsWith('/discover/poster'),isTrue);
    final movie=await create('手工'),id=movie['id'] as String;
    final before=requests.length;
    await expectLater(call('POST',['movies',id,'enrich']),error(501));
    await expectLater(call('GET',['movies',id,'poster']),error(501));
    await expectLater(call('GET',['discover','poster'],query:{'path':'/poster.jpg'}),error(501));
    await expectLater(routes.fetchPoster(fid,'https://unapproved.invalid/a.jpg'),error(400));
    expect(requests.length,before);expect(((await call('GET',['movies',id])).data as Map)['ai_status'],'none');
  });
  test('只接受合法字段与家庭成员，跨家庭和伪造状态明确拒绝',()async{
    for(final body in <Json>[{'title':' '},{'title':'字'*81},{'title':'x','note':'字'*501},{'title':'x','created_by':'other'},{'title':'x','watched_at':'2020-01-01'}]){
      await expectLater(call('POST',['movies'],body:body),error(400));
    }
    expect((await routes.movieStats(fid))['total'],0);
    final row=await create('隔离'),id=row['id'] as String;
    await expectLater(call('PUT',['movies',id],body:{'watched':'true'}),error(400));
    await expectLater(call('GET',['movies'],query:{'watched':'yes'}),error(400));
    await expectLater(call('GET',['movies'],family:'other'),error(403));await member('other',store.deviceId);
    await expectLater(call('GET',['movies',id],family:'other'),error(404));
    await store.patch(fid,'/families/$fid/members',store.deviceId,{'status':'revoked'});
    await expectLater(call('GET',['discover']),error(403));expect(requests,isEmpty);
  });
  test('已知非法方法拒绝，未知插件留给根路由且查询参数受限',()async{
    expect(await routes.request('GET',fid,['unimplemented-plugin','items']),isNull);
    expect(await routes.request('GET',fid,['movie','unknown']),isNull);
    await expectLater(call('DELETE',['movies']),error(405));await expectLater(call('POST',['discover']),error(405));
    for(final query in <Json>[{'page':0},{'page':501},{'sort':'bad'},{'genres':'18,bad'},{'unexpected':'x'}]){await expectLater(call('GET',['discover'],query:query),error(400));}
    expect(requests,isEmpty);
  });

  Future<LocalResult> chore(String method,List<String> tail,{Json body=const{},Json query=const{}})async{
    final result=await routes.request(method,fid,['chore','chores',...tail],body:body,query:query);expect(result,isNotNull);return result!;
  }
  test('家务CRUD与指派真实头像，身份固定且本地通知原子记录',()async{
    await member(fid,'assignee-b');
    final created=Chore.fromJson(Map<String,dynamic>.from((await chore('POST',[],body:{'title':' 扫地 ','emoji':'🧹','note':'客厅','assigned_to':'assignee-b','recurring':true})).data as Map));
    expect(created.title,'扫地');expect(created.createdBy,store.deviceId);expect(created.assignedTo,'assignee-b');expect(created.assigneeAvatarUrl,'/local/avatar/assignee-b?v=1');
    final notifications=await store.list(fid,'/families/$fid/notifications');expect(notifications,hasLength(1));
    expect(notifications.single['recipient_ids'],['assignee-b']);expect(notifications.single['status'],'pending_local_delivery');expect(notifications.single['type'],'chore_assigned');expect(notifications.single['source_id'],created.id);
    await chore('PUT',[created.id],body:{'title':'擦地','assigned_to':null,'note':null,'recurring':false});
    final changed=Chore.fromJson(Map<String,dynamic>.from((await chore('GET',[created.id])).data as Map));expect(changed.assignedTo,isNull);expect(changed.assigneeAvatarUrl,isNull);expect(changed.note,isNull);expect(changed.recurring,isFalse);
    expect((await chore('DELETE',[created.id])).data,isNull);await expectLater(chore('GET',[created.id]),error(404));expect(requests,isEmpty);
  });
  test('家务完成和重开幂等，列表和当前成员预览只从本地派生',()async{
    final one=Chore.fromJson(Map<String,dynamic>.from((await chore('POST',[],body:{'title':'我做','assigned_to':store.deviceId})).data as Map));
    clock=clock.add(const Duration(seconds:1));final two=Chore.fromJson(Map<String,dynamic>.from((await chore('POST',[],body:{'title':'未指派'})).data as Map));
    expect(await store.list(fid,'/families/$fid/notifications'),isEmpty);
    expect((await routes.choreStats(fid))['mine_open'],1);expect((await routes.chorePreview(fid))['primary'],'1 件家务待做');
    final done=await chore('POST',[one.id,'complete']);final timestamp=(done.data as Map)['completed_at'];
    clock=clock.add(const Duration(hours:3));expect(((await chore('POST',[one.id,'complete'])).data as Map)['completed_at'],timestamp);
    expect(((await chore('PUT',[one.id],body:{'done':true})).data as Map)['completed_at'],timestamp);
    final list=(await chore('GET',[])).data as List;expect(list.map((row)=>(row as Map)['id']),[two.id,one.id]);
    expect(((await chore('GET',[],query:{'done':true})).data as List).single['id'],one.id);
    expect(((await chore('POST',[one.id,'reopen'])).data as Map)['completed_at'],isNull);
    expect(((await chore('POST',[one.id,'reopen'])).data as Map)['done'],isFalse);
    expect(requests,isEmpty);
  });
  test('指派仅变化时记录请求，手动提醒明示未送达系统，失效指派拒绝',()async{
    await member(fid,'assignee-b');await member(fid,'assignee-c');
    final raw=(await chore('POST',[],body:{'title':'家务','assigned_to':'assignee-b'})).data as Map;final id=raw['id'] as String;
    await chore('PUT',[id],body:{'title':'改名','assigned_to':'assignee-b'});expect(await store.list(fid,'/families/$fid/notifications'),hasLength(1));
    await chore('PUT',[id],body:{'assigned_to':'assignee-c'});expect(await store.list(fid,'/families/$fid/notifications'),hasLength(2));
    final remind=(await chore('POST',[id,'remind'])).data as Map;expect(remind['status'],'pending_local_delivery');expect(remind['system_delivered'],isFalse);expect(remind['reminded'],'assignee-c');
    expect(await store.list(fid,'/families/$fid/notifications'),hasLength(3));
    await chore('POST',[id,'complete']);await expectLater(chore('POST',[id,'remind']),error(400));
    await chore('POST',[id,'reopen']);await store.patch(fid,'/families/$fid/members','assignee-c',{'status':'left'});
    await expectLater(chore('POST',[id,'remind']),error(400));expect(await store.list(fid,'/families/$fid/notifications'),hasLength(3));
    expect(requests,isEmpty);
  });
  test('重置重复家务保留负责人，不重置一次性或已打开任务',()async{
    await member(fid,'assignee-b');final ids=<String>[];
    for(final recurring in [true,true,false]){final raw=(await chore('POST',[],body:{'title':'重复允许同名','assigned_to':'assignee-b','recurring':recurring})).data as Map;ids.add(raw['id'] as String);await chore('POST',[ids.last,'complete']);}
    final open=(await chore('POST',[],body:{'title':'已打开','recurring':true})).data as Map;
    final before=(await store.list(fid,'/families/$fid/notifications')).length;
    expect((await chore('POST',['reset-recurring'])).data,{'reset':2});
    expect(((await chore('GET',[ids[0]])).data as Map)['assigned_to'],'assignee-b');expect(((await chore('GET',[ids[1]])).data as Map)['completed_at'],isNull);
    expect(((await chore('GET',[ids[2]])).data as Map)['done'],isTrue);expect(((await chore('GET',[open['id'] as String])).data as Map)['done'],isFalse);
    expect((await chore('POST',['reset-recurring'])).data,{'reset':0});expect((await store.list(fid,'/families/$fid/notifications')).length,before);
  });
  test('家务输入、伪造身份、非法负责人和空指派提醒拒绝不留通知',()async{
    for(final body in <Json>[{'title':' '},{'title':'x'*65},{'title':'x','emoji':null},{'title':'x','recurring':'true'},{'title':'x','assigned_to':'outsider'},{'title':'x','created_by':'forged'},{'title':'x','done':true}]){
      await expectLater(chore('POST',[],body:body),error(400));
    }
    expect((await routes.choreStats(fid))['total'],0);expect(await store.list(fid,'/families/$fid/notifications'),isEmpty);
    final raw=(await chore('POST',[],body:{'title':'未指派'})).data as Map;await expectLater(chore('POST',[raw['id'] as String,'remind']),error(400));
    await expectLater(chore('GET',[],query:{'done':'invalid'}),error(400));await expectLater(chore('GET',['reset-recurring']),error(405));
    expect(requests,isEmpty);
  });
  test('家务通知与任务写入同批失败不会留下半成品',()async{
    await member(fid,'assignee-b');
    // 真实业务调用的第二份文档在 SQLite 层失败，不能留下已创建任务/序号。
    await store.db.execute("CREATE TRIGGER reject_notification BEFORE INSERT ON documents WHEN NEW.collection = '/families/$fid/notifications' BEGIN SELECT RAISE(ABORT, 'synthetic notification persistence failure'); END");
    final before=await store.vector(fid);
    await expectLater(chore('POST',[],body:{'title':'不应保留','assigned_to':'assignee-b'}),throwsA(predicate((e)=>'$e'.contains('synthetic notification persistence failure'))));
    expect(await store.list(fid,'/families/$fid/plugins/chore/chores'),isEmpty);
    expect(await store.list(fid,'/families/$fid/notifications'),isEmpty);expect(await store.vector(fid),before);
  });

  Future<LocalResult> anniversary(String method,List<String> tail,{Json body=const{},Json query=const{}})async{
    final result=await routes.request(method,fid,['anniversary','dates',...tail],body:body,query:query);expect(result,isNotNull);return result!;
  }
  test('纪念日CRUD和模型、真实作者、提醒字段及重启持久',()async{
    final created=await anniversary('POST',[],body:{'name':' 相识 ','event_date':'2020-12-01','emoji':'💞','note':'保留','notify_enabled':true,'notify_days_before':7});
    final model=Anniversary.fromJson(Map<String,dynamic>.from(created.data as Map));expect(model.name,'相识');expect(model.isLunar,isFalse);expect(model.notifyEnabled,isTrue);expect(model.notifyDaysBefore,7);expect(model.daysUntil,11);
    expect((created.data as Map)['created_by'],store.deviceId);expect((created.data as Map)['creator_avatar_url'],'/local/avatar/${store.deviceId}?v=1');
    await anniversary('PUT',[model.id],body:{'name':'改名','note':null,'notify_enabled':false,'notify_days_before':0});
    await store.close();store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/local.sqlite');routes=MovieChoreAnniversaryRoutes(store,now:()=>clock);
    final read=Anniversary.fromJson(Map<String,dynamic>.from((await anniversary('GET',[model.id])).data as Map));expect(read.name,'改名');expect(read.note,isNull);expect(read.eventDate.month,12);expect(read.notifyEnabled,isFalse);expect(read.createdAt,model.createdAt);
    await anniversary('DELETE',[model.id]);await expectLater(anniversary('GET',[model.id]),error(404));expect(requests,isEmpty);
  });
  test('本地农历保留闰月和小月兼容，岁末跨公历年不跳过当前农历年',()async{
    final today=DateTime.utc(2026,1,1);
    expect(LocalAnniversaryCalendar.nextOccurrence(DateTime.utc(2024,3,15),today,isLunar:true),DateTime.utc(2026,3,24));
    expect(LocalAnniversaryCalendar.nextOccurrence(DateTime.utc(2023,4,1),today,isLunar:true),DateTime.utc(2026,3,29));
    expect(LocalAnniversaryCalendar.nextOccurrence(DateTime.utc(2024,2,9),today,isLunar:true),DateTime.utc(2026,2,16));
    expect(LocalAnniversaryCalendar.daysUntil(today,today,isLunar:true),0);
    expect(LocalAnniversaryCalendar.nextOccurrence(DateTime.utc(2024,2,29),today),DateTime.utc(2028,2,29));
    expect(LocalAnniversaryCalendar.daysUntil(DateTime.utc(2024,3,15),DateTime(2026,3,14,23,59)),1);
    clock=today;
    final saved=Anniversary.fromJson(Map<String,dynamic>.from((await anniversary('POST',[],body:{'name':'农历','event_date':'2024-03-15','is_lunar':true})).data as Map));
    expect(saved.isLunar,isTrue);expect(saved.daysUntil,DateTime.utc(2026,3,24).difference(today).inDays);expect(requests,isEmpty);
  });
  test('农历月首官方表回归与年表边界，不把不支持日期改成公历',()async{
    for(final fixture in [
      (DateTime.utc(1954,11,26),1954,11,1),(DateTime.utc(1978,9,3),1978,8,1),
      (DateTime.utc(2057,9,28),2057,9,1),(DateTime.utc(2097,8,7),2097,7,1),
    ]){
      final lunar=LocalAnniversaryCalendar.fromSolar(fixture.$1);expect(lunar.year,fixture.$2);expect(lunar.month,fixture.$3);expect(lunar.day,fixture.$4);expect(lunar.leap,isFalse);
      expect(LocalAnniversaryCalendar.toSolar(lunar.year,lunar.month,lunar.day,leap:lunar.leap),fixture.$1);
    }
    final first=LocalAnniversaryCalendar.fromSolar(DateTime.utc(1900,1,31));expect((first.year,first.month,first.day,first.leap),(1900,1,1,false));
    final last=LocalAnniversaryCalendar.fromSolar(DateTime.utc(2100,2,8));expect(LocalAnniversaryCalendar.toSolar(last.year,last.month,last.day,leap:last.leap),DateTime.utc(2100,2,8));
    expect(()=>LocalAnniversaryCalendar.fromSolar(DateTime.utc(1900,1,30)),throwsUnsupportedError);
    expect(()=>LocalAnniversaryCalendar.fromSolar(DateTime.utc(2100,2,9)),throwsUnsupportedError);
    await expectLater(anniversary('POST',[],body:{'name':'超表','event_date':'1800-01-01','is_lunar':true}),error(501));
    expect((await anniversary('GET',[])).data,isEmpty);
  });
  test('重复日期记录与多卡绑定独立，删除绑定日期仅预览回退不删卡片',()async{
    Future<Json> add(String name,String date,String emoji)async=>Map<String,dynamic>.from((await anniversary('POST',[],body:{'name':name,'event_date':date,'emoji':emoji})).data as Map);
    final a=await add('允许同名','2020-05-20','🅰️'),b=await add('允许同名','2020-05-20','🅱️'),near=await add('近处','2020-12-01','🎉');
    expect(a['id'],isNot(b['id']));expect((await anniversary('GET',[])).data,hasLength(3));
    for(final entry in [('card-a',a['id']),('card-b',b['id'])]){await store.patch(fid,'/families/$fid/installed',entry.$1,{'plugin_id':'anniversary','config':{'anniversary_id':entry.$2}});}
    expect((await routes.anniversaryPreview(fid,config:{'anniversary_id':a['id']}))['emoji'],'🅰️');
    expect((await routes.anniversaryPreview(fid,config:{'anniversary_id':b['id']}))['emoji'],'🅱️');
    expect((await routes.anniversaryPreview(fid))['primary'],'近处');
    await anniversary('DELETE',[a['id'] as String]);
    expect((await routes.anniversaryPreview(fid,config:{'anniversary_id':a['id']}))['primary'],'近处');
    expect((await routes.anniversaryPreview(fid,config:{'anniversary_id':b['id']}))['emoji'],'🅱️');
    expect((await store.get(fid,'/families/$fid/installed','card-a'))!['config'],{'anniversary_id':a['id']});
    expect((await store.get(fid,'/families/$fid/installed','card-b'))!['config'],{'anniversary_id':b['id']});
    expect((await anniversary('GET',[near['id'] as String])).data,isNotNull);
  });
  test('纪念日提醒只记录pending请求，每周年去重且不依卡片数量重复',()async{
    await member(fid,'another-member');clock=DateTime.utc(2026,12,25);
    final due=(await anniversary('POST',[],body:{'name':'明天','event_date':'2020-12-26','notify_enabled':true,'notify_days_before':1})).data as Map;
    await anniversary('POST',[],body:{'name':'未开提醒','event_date':'2020-12-25'});
    await anniversary('POST',[],body:{'name':'窗口外','event_date':'2020-12-31','notify_enabled':true,'notify_days_before':1});
    expect(await routes.requestDueAnniversaryReminders(fid),1);expect(await routes.requestDueAnniversaryReminders(fid),0);
    var notifications=await store.list(fid,'/families/$fid/notifications');expect(notifications,hasLength(1));expect(notifications.single['type'],'anniversary_due');expect(notifications.single['status'],'pending_local_delivery');
    expect(notifications.single['recipient_ids'],containsAll([store.deviceId,'another-member']));expect(notifications.single['source_id'],due['id']);expect(notifications.single['source_occurrence'],'2026-12-26');
    clock=DateTime.utc(2026,12,26);expect(await routes.requestDueAnniversaryReminders(fid),0);
    clock=DateTime.utc(2027,12,25);expect(await routes.requestDueAnniversaryReminders(fid),1);
    notifications=await store.list(fid,'/families/$fid/notifications');expect(notifications,hasLength(2));
    expect(notifications.map((n)=>n['source_occurrence']),containsAll(['2026-12-26','2027-12-26']));expect(requests,isEmpty);
  });
  test('纪念日非法输入/伪造字段不落库，超范围不会返回假倒数零',()async{
    for(final body in <Json>[
      {'name':' ','event_date':'2026-01-01'},{'name':'x'*33,'event_date':'2026-01-01'},
      {'name':'x','event_date':'2026-02-30'},{'name':'x','event_date':'2026-01-01','is_lunar':'true'},
      {'name':'x','event_date':'2026-01-01','notify_days_before':366},{'name':'x','event_date':'2026-01-01','created_by':'forged'},
    ]){await expectLater(anniversary('POST',[],body:body),error(400));}
    expect((await anniversary('GET',[])).data,isEmpty);
    final lunar=(await anniversary('POST',[],body:{'name':'农历','event_date':'2024-03-15','is_lunar':true})).data as Map;
    clock=DateTime.utc(2101,1,1);await expectLater(anniversary('GET',[lunar['id'] as String]),error(501));
    expect((await store.get(fid,'/families/$fid/plugins/anniversary/dates',lunar['id'] as String))!['is_lunar'],isTrue);
    await expectLater(anniversary('DELETE',[]),error(405));expect(requests,isEmpty);
  });
}
