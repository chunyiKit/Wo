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
    expect(await routes.request('GET',fid,['chore','chores']),isNull);
    expect(await routes.request('GET',fid,['movie','unknown']),isNull);
    await expectLater(call('DELETE',['movies']),error(405));await expectLater(call('POST',['discover']),error(405));
    for(final query in <Json>[{'page':0},{'page':501},{'sort':'bad'},{'genres':'18,bad'},{'unexpected':'x'}]){await expectLater(call('GET',['discover'],query:query),error(400));}
    expect(requests,isEmpty);
  });
}
