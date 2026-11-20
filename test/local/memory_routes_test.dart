import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/local/local_backend.dart';
import 'package:wo/local/local_media_repository.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/memory_routes.dart';

class _Access implements MemoryAccess {
  _Access(this.privateSpace,{this.couple});
  final String privateSpace;
  String? couple;
  @override
  Future<List<String>> visibleSpaces(String fid) async=>[fid,privateSpace,if(couple!=null)couple!];
  @override
  Future<String> spaceFor(String fid,String visibility) async {
    if(visibility=='family')return fid;
    if(visibility=='private')return privateSpace;
    if(visibility=='couple'&&couple!=null)return couple!;
    throw ApiException('FORBIDDEN','没有明确伴侣绑定',statusCode:403);
  }
}
class _Item implements LocalMediaItem {
  _Item(this.id,{this.kind='photo'});
  @override final String id;
  @override final String kind;
  @override String get thumbnailSha256=>'a'*64;
  @override int get width=>32;
  @override int get height=>24;
  @override int get durationMs=>kind=='video'?1200:0;
  @override String get contentType=>'image/jpeg';
  @override int get sizeBytes=>128;
  @override String get url=>'wo-local-media://$id/thumbnail';
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class _Media implements LocalMediaRepository {
  final values=<String,LocalMediaItem>{};
  final attachments=<String,List<LocalMediaItem>>{};
  final reads=<String>[];
  @override Future<List<LocalMediaItem>> forMemory(String space,String id) async {
    reads.add('$space/$id');return List<LocalMediaItem>.of(attachments['$space/$id']??[]);
  }
  @override Future<void> attach(String space,String id,String mediaId) async {
    final item=values[mediaId];if(item==null)throw ApiException('NOT_FOUND','媒体不存在',statusCode:404);
    final key='$space/$id';final list=attachments.putIfAbsent(key,()=>[]);
    if(!list.any((m)=>m.id==mediaId))list.add(item);
  }
  @override Future<void> detach(String space,String id,String mediaId) async {
    attachments['$space/$id']?.removeWhere((m)=>m.id==mediaId);
  }
  @override Future<File?> thumbnailFile(String id) async=>null;
  @override Future<Map<String,dynamic>> originalAvailability(String id) async=>{'available':false,'reason':'source_unavailable'};
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}

void main(){
  sqfliteFfiInit();
  const fid='family';
  late Directory directory;
  late LocalStore a,b,c;
  late _Access accessA,accessB,accessC;
  late _Media mediaA,mediaB,mediaC;
  late MemoryRoutes routesA,routesB,routesC;
  late DateTime clock;
  Matcher error(int status)=>throwsA(isA<ApiException>().having((e)=>e.statusCode,'status',status));
  Future<LocalResult> call(MemoryRoutes routes,String method,List<String> tail,{Json body=const{},Json query=const{}}) async {
    final result=await routes.request(method,fid,['memory','memories',...tail],body:body,query:query);
    expect(result,isNotNull);return result!;
  }
  Future<Json> create(MemoryRoutes routes,String title,{String? visibility,String date='2026-11-20',String? client}) async=>Map<String,dynamic>.from(
    (await call(routes,'POST',[],body:{'title':title,'event_date':date,if(visibility!=null)'visibility':visibility,if(client!=null)'client_id':client})).data as Map);
  Future<void> seed(LocalStore destination) async {
    for(final member in [a,b,c]){
      await destination.patch(fid,'/families/$fid/members',member.deviceId,{
        'user_id':member.deviceId,'family_id':fid,'status':'active','role':'member',
        'display_name':member==a?'甲':member==b?'乙':'丙','avatar_emoji':'🐱',
        'avatar_url':'/local/avatar/${member.deviceId}?v=1',
      });
    }
  }
  Future<void> transfer(LocalStore from,LocalStore to,String space) async {
    // 实际增量 API 每批最多256，不靠一次合并无限数据的测试捷径。
    for(var repeat=0;repeat<100;repeat++){
      final batch=await from.exportSince(space,await to.vector(space));
      if(batch.isEmpty)return;
      await to.merge(space,batch);
    }
    fail('增量未结束');
  }
  setUp(() async {
    directory=await Directory.systemTemp.createTemp('wo-memory-routes-');
    a=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/a.sqlite');
    b=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/b.sqlite');
    c=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/c.sqlite');
    for(final store in [a,b,c]){await seed(store);}
    clock=DateTime(2026,11,20,12);
    accessA=_Access('private-a',couple:'couple-ab');accessB=_Access('private-b',couple:'couple-ab');accessC=_Access('private-c');
    mediaA=_Media();mediaB=_Media();mediaC=_Media();
    routesA=MemoryRoutes(a,media:mediaA,access:accessA,now:()=>clock);
    routesB=MemoryRoutes(b,media:mediaB,access:accessB,now:()=>clock);
    routesC=MemoryRoutes(c,media:mediaC,access:accessC,now:()=>clock);
  });
  tearDown(() async {await a.close();await b.close();await c.close();await directory.delete(recursive:true);});

  test('默认私密的正文 CRUD 与真实头像，重启仍可解码',() async {
    final created=Memory.fromJson(await create(routesA,' 标题 '));
    expect(created.visibility,'private');expect(created.title,'标题');expect(created.createdBy,a.deviceId);
    expect(created.authorName,'甲');expect(created.authorAvatarUrl,'/local/avatar/${a.deviceId}?v=1');
    expect(await a.list(fid,'/families/$fid/plugins/memory/memories'),isEmpty);
    final changed=Memory.fromJson(Map<String,dynamic>.from((await call(routesA,'PUT',[created.id],body:{
      'title':'新标题','body':'原文','location':'本机地点','mood':'😌','event_date':'2010-01-01','visibility':'private',
    })).data as Map));
    expect(changed.body,'原文');expect(changed.eventDate.year,2010);
    await call(routesA,'PATCH',[created.id],body:{'body':null,'location':null,'mood':null});
    await a.close();a=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/a.sqlite');
    routesA=MemoryRoutes(a,media:mediaA,access:accessA,now:()=>clock);
    final read=Memory.fromJson(Map<String,dynamic>.from((await call(routesA,'GET',[created.id])).data as Map));
    expect(read.title,'新标题');expect(read.body,isNull);expect(read.createdBy,created.createdBy);
    await a.patch(fid,'/families/$fid/members',a.deviceId,{'display_name':'甲改名','avatar_url':'/local/avatar/new?v=2'});
    final updated=await routesA.visibleMemory(fid,created.id);expect(updated!['author_name'],'甲改名');expect(updated['author_avatar_url'],'/local/avatar/new?v=2');
  });
  test('同家庭不同成员的标题计数留言缩略图与旅行选择快照无越权泄漏',() async {
    final public=await create(routesA,'全家',visibility:'family');
    final secret=await create(routesA,'甲的私密标题');
    final couple=await create(routesA,'甲乙伴侣标题',visibility:'couple');
    await call(routesA,'POST',[secret['id'] as String,'comments'],body:{'body':'私密留言正文'});
    await call(routesA,'POST',[couple['id'] as String,'comments'],body:{'body':'伴侣留言正文'});
    mediaA.values['private-thumb']=_Item('private-thumb');await routesA.attachMedia(fid,secret['id'] as String,'private-thumb');
    final familyLog=LocalStore.canonical(await a.exportSince(fid,{}));
    for(final text in ['甲的私密标题','私密留言正文','甲乙伴侣标题','伴侣留言正文','private-thumb']){expect(familyLog,isNot(contains(text)));}
    await transfer(a,b,fid);await transfer(a,c,fid);await transfer(a,b,'couple-ab');
    final pageB=await call(routesB,'GET',[]);final pageC=await call(routesC,'GET',[]);
    expect(pageB.meta!['total'],2);expect(pageC.meta!['total'],1);
    expect((pageC.data as List).single['id'],public['id']);
    final previewB=await routesB.visibleSnapshot(fid),previewC=await routesC.visibleSnapshot(fid);
    expect(previewB.map((m)=>m['title']),containsAll(['全家','甲乙伴侣标题']));
    expect(previewB.map((m)=>m['title']),isNot(contains('甲的私密标题')));
    expect(previewC.map((m)=>m['title']),['全家']);
    expect(await routesA.referenceForSpace(fid,secret['id'] as String,fid),isNull);
    expect(await routesA.referenceForSpace(fid,couple['id'] as String,fid),isNull);
    expect((await routesA.referenceForSpace(fid,couple['id'] as String,'couple-ab'))!['title'],'甲乙伴侣标题');
    expect((await routesA.referenceForSpace(fid,public['id'] as String,'private-a'))!['title'],'全家');
    expect(await routesC.referenceForSpace(fid,couple['id'] as String,'couple-ab'),isNull);
    expect(await routesB.visibleMemory(fid,secret['id'] as String),isNull);
    expect(await routesC.visibleMemory(fid,couple['id'] as String),isNull);
    for(final routes in [routesB,routesC]){
      await expectLater(call(routes,'GET',[secret['id'] as String]),error(404));
      await expectLater(call(routes,'POST',[secret['id'] as String,'comments'],body:{'body':'越权'}),error(404));
      await expectLater(routes.attachMedia(fid,secret['id'] as String,'private-thumb'),error(404));
    }
    expect(mediaB.reads.any((key)=>key.startsWith('private-a/')),isFalse);
    expect(mediaC.reads.any((key)=>key.startsWith('private-a/')||key.startsWith('couple-ab/')),isFalse);
  });
  test('伴侣无明确绑定拒绝创建；撤销可见授权后计数与媒体同时隐藏',() async {
    await expectLater(create(routesC,'不能回落',visibility:'couple'),error(403));
    expect(await c.list(fid,'/families/$fid/plugins/memory/memories'),isEmpty);
    final memory=await create(routesA,'伴侣',visibility:'couple');await transfer(a,b,'couple-ab');
    expect((await call(routesB,'GET',[])).meta!['total'],1);
    accessB.couple=null;
    expect((await call(routesB,'GET',[])).meta!['total'],0);
    expect(await routesB.visibleSnapshot(fid),isEmpty);
    await expectLater(call(routesB,'GET',[memory['id'] as String]),error(404));
  });
  test('可见范围固定，非授权 author 和原件字段不能进入业务操作',() async {
    final created=await create(routesA,'私密');final id=created['id'] as String;
    final before=await a.vector('private-a');
    for(final visibility in ['family','couple']){await expectLater(call(routesA,'PUT',[id],body:{'visibility':visibility,'body':'不应提交'}),error(409));}
    for(final field in ['created_by','family_id','author_avatar_url','locator','source_original','media']){
      await expectLater(call(routesA,'POST',[],body:{'title':'禁止',field:'secret'}),error(400));
    }
    await expectLater(call(routesA,'POST',[id,'media'],body:{'media_id':'one','locator':'content://private-original'}),error(400));
    expect(await a.vector('private-a'),before);
    expect((await routesA.visibleMemory(fid,id))!['body'],isNull);
  });
  test('留言模型与真实头像、仅作者删除及父记录删除后子资源不可达',() async {
    final memory=await create(routesA,'共享',visibility:'family'),id=memory['id'] as String;
    final comment=MemoryComment.fromJson(Map<String,dynamic>.from((await call(routesA,'POST',[id,'comments'],body:{'body':' 留言 '})).data as Map));
    expect(comment.body,'留言');expect(comment.authorId,a.deviceId);expect(comment.authorAvatarUrl,'/local/avatar/${a.deviceId}?v=1');
    await transfer(a,b,fid);
    await expectLater(call(routesB,'DELETE',[id,'comments',comment.id]),error(403));
    final detail=Memory.fromJson(Map<String,dynamic>.from((await call(routesB,'GET',[id])).data as Map));
    expect(detail.comments.single.body,'留言');expect(detail.commentCount,1);
    final listing=(await call(routesB,'GET',[])).data as List;
    expect(listing.single['comments'],isEmpty);expect(listing.single['comment_count'],1);
    await call(routesA,'DELETE',[id,'comments',comment.id]);
    expect((await routesA.visibleMemory(fid,id))!['comment_count'],0);
    await call(routesA,'DELETE',[id]);
    await expectLater(call(routesA,'POST',[id,'comments'],body:{'body':'已删除父记录'}),error(404));
  });
  test('稳定 client_id 并发重试不重复，永久墓碑不能复活',() async {
    const client='12345678-1234-4234-8234-123456789abc';
    final results=await Future.wait([create(routesA,'一次',client:client),create(routesA,'重试不覆盖',client:client)]);
    expect(results.map((m)=>m['id']),[client,client]);
    expect((await routesA.visibleSnapshot(fid)).single['title'],'一次');
    await expectLater(create(routesA,'不能转换',client:client,visibility:'family'),error(409));
    expect((await call(routesA,'DELETE',[client])).data,isNull);
    expect((await call(routesA,'DELETE',[client])).data,isNull);
    await expectLater(create(routesA,'复活',client:client),error(409));
    await expectLater(call(routesA,'PUT',[client],body:{'title':'迟到编辑'}),error(404));
    await expectLater(call(routesA,'DELETE',['never-existed']),error(404));
  });
  test('keyset 覆盖补录较早日期和同日微秒，游标只属于当前成员授权范围',() async {
    clock=DateTime.utc(2026,11,20,0,0,0,0,1);final one=await create(routesA,'微秒一',visibility:'family');
    clock=DateTime.utc(2026,11,20,0,0,0,0,2);final two=await create(routesA,'微秒二',visibility:'family');
    clock=DateTime.utc(2026,11,20,1);final old=await create(routesA,'补录很早',visibility:'family',date:'2000-01-01');
    final first=await call(routesA,'GET',[],query:{'limit':1});expect((first.data as List).single['id'],two['id']);expect(first.meta!['total'],3);
    final second=await call(routesA,'GET',[],query:{'limit':'1','cursor':first.meta!['cursor']});expect((second.data as List).single['id'],one['id']);
    final third=await call(routesA,'GET',[],query:{'limit':1,'cursor':second.meta!['cursor']});expect((third.data as List).single['id'],old['id']);expect(third.meta!['cursor'],isNull);
    await transfer(a,b,fid);await expectLater(call(routesB,'GET',[],query:{'cursor':first.meta!['cursor']}),error(400));
    accessA.couple=null;await expectLater(call(routesA,'GET',[],query:{'cursor':first.meta!['cursor']}),error(400));
  });
  test('已删游标锚点仍可翻页；非法日期输入和畸形分页均拒绝',() async {
    final newer=await create(routesA,'新',date:'2026-11-20');final older=await create(routesA,'旧',date:'2001-01-01');
    final first=await call(routesA,'GET',[],query:{'limit':1});await call(routesA,'DELETE',[newer['id'] as String]);
    final next=await call(routesA,'GET',[],query:{'limit':1,'cursor':first.meta!['cursor']});expect((next.data as List).single['id'],older['id']);expect(next.meta!['total'],1);
    for(final query in <Json>[{'limit':0},{'limit':51},{'limit':true},{'limit':1.5},{'cursor':'not-base64!'}]){await expectLater(call(routesA,'GET',[],query:query),error(400));}
    for(final body in <Json>[{'title':' '},{'title':'x'*81},{'title':'x','body':'x'*2001},{'title':'x','event_date':'2026-02-30'},{'title':'x','visibility':null},{'title':'x','client_id':'bad-id'}]){await expectLater(call(routesA,'POST',[],body:body),error(400));}
    expect((await routesA.visibleSnapshot(fid)).length,1);
  });
  test('媒体挂接幂等限额及模型解码，授权前不读取私密缩略图',() async {
    final memory=await create(routesA,'媒体'),id=memory['id'] as String;
    for(var i=0;i<10;i++){mediaA.values['media-$i']=_Item('media-$i',kind:i==0?'video':'photo');}
    for(var i=0;i<9;i++){await routesA.attachMedia(fid,id,'media-$i');}
    final again=await routesA.attachMedia(fid,id,'media-0');expect(MemoryMedia.fromJson(again).isVideo,isTrue);
    await expectLater(routesA.attachMedia(fid,id,'media-9'),error(400));
    final detail=Memory.fromJson(Map<String,dynamic>.from((await call(routesA,'GET',[id])).data as Map));
    expect(detail.media,hasLength(9));expect(detail.media.first.url,'wo-local-media://media-0/thumbnail');expect(detail.media.first.sizeBytes,128);
    await routesA.removeMedia(fid,id,'media-0');await routesA.attachMedia(fid,id,'media-9');
    await expectLater(routesB.removeMedia(fid,id,'media-1'),error(404));expect(mediaB.reads,isEmpty);
    await call(routesA,'DELETE',[id]);expect(await mediaA.forMemory('private-a',id),isEmpty);
  });
  test('大量留言删除分批写墓碑，重复删除可重试且不承认隐藏活记录',() async {
    final memory=await create(routesA,'很多留言'),id=memory['id'] as String;
    final col='/families/private-a/plugins/memory/memories/$id/comments';
    for(var start=0;start<270;start+=100){await a.batch([for(var i=start;i<start+100&&i<270;i++){
      'space':'private-a','collection':col,'id':'comment-$i','fields':{
        'family_id':fid,'memory_id':id,'body':'留言$i','created_by':a.deviceId,'created_at':'2026-11-20T00:00:00Z',
      },
    }]);}
    await call(routesA,'DELETE',[id]);expect(await a.list('private-a',col),isEmpty);
    await call(routesA,'DELETE',[id]);
    // 错放在可见物理空间的别人成员私密记录也不能因 revision>0 被当作墓碑。
    await a.patch('private-a','/families/private-a/plugins/memory/memories','hidden-live',{
      'family_id':fid,'visibility':'private','created_by':b.deviceId,'title':'不可操作','event_date':'2026-01-01','created_at':'2026-11-20T00:00:00Z',
    });
    await expectLater(call(routesA,'DELETE',['hidden-live']),error(404));
    expect(await a.get('private-a','/families/private-a/plugins/memory/memories','hidden-live'),isNotNull);
  });
  test('无效成员/错误方法和旧云媒体路径均明确失败',() async {
    expect(await routesA.request('GET',fid,['memory','unknown']),isNull);
    await expectLater(call(routesA,'PATCH',[]),error(405));
    final memory=await create(routesA,'本机'),id=memory['id'] as String;
    await expectLater(call(routesA,'GET',[id,'media','one','raw']),error(501));
    await expectLater(call(routesA,'POST',[id,'media','presign']),error(501));
    await a.patch(fid,'/families/$fid/members',a.deviceId,{'status':'revoked'});
    await expectLater(call(routesA,'GET',[]),error(403));
    await expectLater(routesA.visibleSnapshot(fid),error(403));
    await expectLater(routesA.attachMedia(fid,id,'one'),error(403));
  });
}
