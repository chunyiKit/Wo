import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/local/backup/backup_models.dart';
import 'package:wo/local/local_backend.dart';
import 'package:wo/local/local_media_repository.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/media/native_media.dart';
import 'package:wo/local/plugins/memory_routes.dart';
import 'package:wo/local/plugins/travel_routes.dart';
import 'package:wo/services/external_services.dart';

class _Access implements MemoryAccess {
  @override Future<List<String>> visibleSpaces(String fid)async=>[fid,'p_owner','c_partner'];
  @override Future<String> spaceFor(String fid,String visibility)async=>switch(visibility){'family'=>fid,'private'=>'p_owner',_=>'c_partner'};
}
class _Native extends NativeMedia {
  int originalReads=0;
  @override Future<Uint8List> read(String handle,{required int offset,int maxBytes=1024*1024})async{originalReads++;throw StateError('原件不应交给模型');}
}
class _Images implements ConfiguredImageClient {
  ImageModelConfig? config=ImageModelConfig(baseUrl:Uri.parse('https://model.example/v1'),apiKey:'synthetic-test-value',model:'test-image-model',retentionNotice:'测试供应商按其政策保留输入；请阅读');
  int calls=0;
  bool fail=false;
  Uint8List? sent;
  @override Future<ImageModelConfig?> Function() get loadConfig=>()async=>config;
  @override Future<GeneratedImage> generate({required PreparedModelImage image,required String prompt,required ImageGenerationConsent consent})async{
    calls++;sent=image.bytes;
    if(fail)throw const ExternalServiceException('图片生成',ServiceFailure.network,requestMayHaveBeenSent:true);
    return GeneratedImage.validated(jpeg);
  }
  @override dynamic noSuchMethod(Invocation i)=>super.noSuchMethod(i);
}
final jpeg=Uint8List.fromList(base64Decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDzGiiiuw5T/9k='));
void main(){
  sqfliteFfiInit();
  const fid='family',source='original-photo',trip='trip-stable';
  late Directory dir;
  late LocalStore store;
  late LocalMediaRepository media;
  late MemoryRoutes memories;
  late TravelRoutes routes;
  late _Images images;
  late _Native native;
  late DateTime time;
  Matcher error(int status)=>throwsA(isA<ApiException>().having((e)=>e.statusCode,'status',status));
  Future<LocalResult> call(String method,List<String> tail,{Json body=const{}})async=>(await routes.request(method,fid,['travel','trips',...tail],body:body))!;
  Json createBody({String? memory})=>{'client_id':trip,'media_id':source,'city_name':'杭州','city_lng':120.15,'city_lat':30.27,'place':'西湖','caption':'本机旅行',if(memory!=null)'memory_id':memory};
  Future<Json> create({String? memory})async=>Json.from((await call('POST',[],body:createBody(memory:memory))).data as Map);
  ImageGenerationConsent consent(TravelGenerationPlan plan,{bool allow=true})=>ImageGenerationConsent(endpoint:plan.endpoint,retentionNotice:plan.retentionNotice,allowSourceUpload:allow,providerPolicyReviewed:true,expectedModel:plan.modelLabel);
  Future<String> createMemory(String visibility)async{
    final result=await memories.request('POST',fid,['memory','memories'],body:{'title':'不可泄漏的$visibility标题','visibility':visibility,'event_date':'2026-11-20'});
    return (result!.data as Map)['id'] as String;
  }
  setUp(()async{
    dir=await Directory.systemTemp.createTemp('wo-local-travel-');
    store=await LocalStore.open(factory:databaseFactoryFfi,path:'${dir.path}/local.sqlite');
    await store.patch(fid,'/families/$fid/members',store.deviceId,{'family_id':fid,'user_id':store.deviceId,'status':'active','role':'owner','display_name':'测试者'});
    native=_Native();media=LocalMediaRepository(store,native:native,directory:Directory('${dir.path}/media'));
    await media.directory.create();await File('${media.directory.path}/$source.jpg').writeAsBytes(jpeg);
    await store.saveDeviceReference(source,'photo','00000000-0000-4000-8000-000000000001',{'kind':'photo','thumbnail_sha256':LocalMediaRepository.hash(jpeg),'thumbnail_bytes':jpeg.length,'width':16,'height':16,'duration_ms':0,'selected_at':'2026-11-20T00:00:00.000Z','source_exact':false,'scope':null,'memory_id':null});
    memories=MemoryRoutes(store,media:media,access:_Access());images=_Images();time=DateTime.utc(2026,11,20);
    routes=TravelRoutes(store,media:media,memories:memories,imageClient:images,now:()=>time,encodeThumbnail:(_)async=>jpeg);
  });
  tearDown(()async{await store.close();await dir.delete(recursive:true);});
  test('创建幂等且保留稳定原照引用，不自动调用模型',()async{
    final a=await create(),b=await create();expect(a['id'],trip);expect(b['id'],trip);expect((await routes.snapshot(fid)).length,1);expect(images.calls,0);
    expect(a['ai_status'],'none');expect(a['image_url'],'wo-local-travel://$source/thumbnail');
    final ref=await store.deviceReference(source);expect(ref!['locator'],'00000000-0000-4000-8000-000000000001');
    final wire=jsonEncode(await store.exportSince(fid,{}));expect(wire, isNot(contains(ref['locator'])));expect(wire,isNot(contains('source_exact')));
    await expectLater(call('POST',[],body:{...createBody(),'caption':'不同请求'}),error(409));
  });
  test('私密与伴侣关联在写入前拒绝，不泄漏ID标题计数',()async{
    for(final visibility in ['private','couple']){
      final id=await createMemory(visibility);await expectLater(create(memory:id),error(404));
      expect(await store.list(fid,'/families/$fid/plugins/travel/trips'),isEmpty);
      final wire=jsonEncode(await store.exportSince(fid,{}));expect(wire,isNot(contains(id)));expect(wire,isNot(contains('不可泄漏')));
      expect(await routes.maySyncTrip(fid,{'memory_id':id}),isFalse);
    }
  });
  test('全家关联即时投影，删除后不返回旧摘要或ID',()async{
    final id=await createMemory('family');final row=await create(memory:id);expect((row['memory'] as Map)['id'],id);
    await memories.request('DELETE',fid,['memory','memories',id]);final reread=(await routes.snapshot(fid)).single;
    expect(reread['memory_id'],isNull);expect(reread['memory'],isNull);expect(await routes.maySyncTrip(fid,{'memory_id':id}),isTrue);
  });
  test('已绑定回忆或跨范围媒体不得重新绑定全家旅行',()async{
    final ref=await store.deviceReference(source),meta=Json.from(jsonDecode(ref!['metadata'] as String) as Map)..addAll({'scope':'p_owner','memory_id':'private-memory'});
    await store.saveDeviceReference(source,'photo',ref['locator'] as String,meta);
    await expectLater(create(),error(403));expect(await store.list(fid,'/families/$fid/plugins/travel/media'),isEmpty);
  });
  test('无本机原照引用的远端缩略图不能用于模型',()async{
    await create();await store.db.delete('device_refs',where:'id=?',whereArgs:[source]);
    await expectLater(routes.planGeneration(fid,trip),error(409));expect(images.calls,0);
  });
  test('坐标未知字段和无授权retry在远程调用前拒绝',()async{
    await expectLater(call('POST',[],body:{...createBody(),'city_lat':double.nan}),error(400));
    await expectLater(call('POST',[],body:{...createBody(),'original_bytes':[1,2,3]}),error(400));
    await create();await expectLater(call('POST',[trip,'retry']),error(409));expect(images.calls,0);
  });
  test('每次授权绑定副本与模型政策，拒绝未同意及复用计划',()async{
    await create();final plan=await routes.planGeneration(fid,trip);
    await expectLater(routes.generate(fid,trip,plan:plan,consent:consent(plan,allow:false)),error(409));expect(images.calls,0);
    final result=await routes.generate(fid,trip,plan:plan,consent:consent(plan));expect(result['id'],trip);expect(result['ai_status'],'ready');
    await expectLater(routes.generate(fid,trip,plan:plan,consent:consent(plan)),error(409));expect(images.calls,1);expect(images.sent,jpeg);expect(native.originalReads,0);
  });
  test('计划过期或源内容变化后须重新确认',()async{
    await create();final plan=await routes.planGeneration(fid,trip);time=time.add(const Duration(minutes:11));
    await expectLater(routes.generate(fid,trip,plan:plan,consent:consent(plan)),error(409));expect(images.calls,0);
  });
  test('确认后同端点切换模型须重新授权，不发送给新模型',()async{
    await create();final plan=await routes.planGeneration(fid,trip),old=images.config!;
    images.config=ImageModelConfig(baseUrl:old.baseUrl,apiKey:'synthetic-test-value',model:'different-model',retentionNotice:old.retentionNotice);
    await expectLater(routes.generate(fid,trip,plan:plan,consent:consent(plan)),error(409));expect(images.calls,0);
    expect((await routes.snapshot(fid)).single['ai_status'],'none');
  });
  test('模型失败可在同一条记录重试，保留原照与历次结果',()async{
    await create();images.fail=true;var plan=await routes.planGeneration(fid,trip);final failed=await routes.generate(fid,trip,plan:plan,consent:consent(plan));
    expect(failed['ai_status'],'failed');expect(failed['generation_error'],'network');expect((await routes.snapshot(fid)).length,1);
    images.fail=false;
    for(var attempt=0;attempt<2;attempt++){plan=await routes.planGeneration(fid,trip);await routes.generate(fid,trip,plan:plan,consent:consent(plan));}
    expect(await store.list(fid,'/families/$fid/plugins/travel/artifacts'),hasLength(2));expect(await store.deviceReference(source),isNotNull);expect(images.calls,3);
  });
  test('缺配置不阻止读取本地记录，也不冒充已生成',()async{
    await create();images.config=null;await expectLater(routes.planGeneration(fid,trip),error(503));expect((await routes.snapshot(fid)).single['ai_status'],'none');expect(images.calls,0);
  });
  test('生成缩略图失败仍保留原字节备份并明确预览缺件',()async{
    routes=TravelRoutes(store,media:media,memories:memories,imageClient:images,encodeThumbnail:(_)async=>throw StateError('synthetic codec unavailable'));
    await create();final plan=await routes.planGeneration(fid,trip);final result=await routes.generate(fid,trip,plan:plan,consent:consent(plan));
    expect(result['ai_status'],'failed');expect(result['generation_error'],'preview_unavailable');
    final backup=await routes.generatedBackupSource(fid,result['generated_media_id'] as String);
    expect(backup.entry.sourceExact,isTrue);expect(backup.entry.sha256,LocalMediaRepository.hash(jpeg));
    final chunks=await (await backup.openRange(0,backup.entry.size)).toList();expect(chunks.expand((e)=>e).toList(),jpeg);
  });
  test('本机中断生成只恢复失败状态，不自动重发模型请求',()async{
    await create();const attempt='inflight-attempt';
    await store.patch(fid,'/families/$fid/plugins/travel/trips',trip,{'ai_status':'generating','generation_attempt':attempt});
    await store.setPrivate('travel-inflight:$fid:$trip',attempt);
    await routes.recoverInterrupted(fid);
    expect((await routes.snapshot(fid)).single['generation_error'],'interrupted');expect(images.calls,0);
    expect(await store.privateValue('travel-inflight:$fid:$trip'),isNull);
  });
  test('删除旅行不删除授权来源或电脑可用原件句柄',()async{
    await create();await call('DELETE',[trip]);expect(await routes.snapshot(fid),isEmpty);expect(await store.deviceReference(source),isNotNull);expect(await File('${media.directory.path}/$source.jpg').exists(),isTrue);
  });
}
