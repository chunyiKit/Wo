// 集成回归已准备；未执行Dart/Flutter/SDK，不证明真实握手、媒体或平台运行。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/local/local_media_repository.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/media/native_media.dart';
import 'package:wo/local/plugins/memory_routes.dart';
import 'package:wo/local/plugins/travel_routes.dart';
import 'package:wo/local/sync/peer_registry.dart';
import 'package:wo/local/sync/sync_policy.dart';
import 'package:wo/local/sync/travel_sync_adapter.dart';
import 'package:wo/local/transport/native_local.dart';

const fid='travel-policy-family',remote='remote-device',stamp='2026-11-20T00:00:00.000Z';
const linkId='11111111-1111-4111-8111-111111111111',secondLink='22222222-2222-4222-8222-222222222222';
const nativeHandle='33333333-3333-4333-8333-333333333333';
final jpeg=Uint8List.fromList(base64Decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDzGiiiuw5T/9k='));
class _Access implements MemoryAccess {
  @override Future<List<String>> visibleSpaces(String family)async=>[family];
  @override Future<String> spaceFor(String family,String visibility)async=>family;
}
class _Registry implements PeerRegistry {
  _Registry(this.store):crypto=NativeCrypto();
  @override final LocalStore store;
  @override final LocalCrypto crypto;
  Set<String> allowed={fid};
  @override Future<Set<String>> scopes(PeerLink peer)async=>Set.of(allowed);
  @override dynamic noSuchMethod(Invocation i)=>super.noSuchMethod(i);
}
class _NoOriginal extends NativeMedia {
  int reads=0,prepared=0;
  @override Future<Uint8List> read(String handle,{required int offset,int maxBytes=1024*1024})async{reads++;throw StateError('原件不能进入同步策略');}
  @override Future<NativeMediaRef> prepareOriginal(String handle)async{prepared++;throw StateError('同步不能触发备份原件准备');}
}
class _CountMedia extends LocalMediaRepository {
  _CountMedia(LocalStore store,{required NativeMedia native,required Directory directory}):super(store,native:native,directory:directory);
  int fileProbes=0;
  @override Future<File?> thumbnailFile(String id)async{fileProbes++;return super.thumbnailFile(id);}
}
PeerLink peer({String id=linkId})=>PeerLink(id:id,familyId:fid,remoteDeviceId:remote,secretRef:'wo.sync.link.$id',remoteRole:'member');
Json trip(String source,{String author=remote})=>{'family_id':fid,'created_by':author,'created_at':stamp,'updated_at':stamp,
  'city_name':'杭州','city_lng':120.1,'city_lat':30.2,'place':null,'caption':'本机旅行','original_media_id':source,'display_media_id':source,
  'generated_media_id':null,'ai_status':'none','generation_attempt':null,'generation_error':null,'memory_id':null};
Json travelMedia(String parent,{String author=remote})=>{'trip_id':parent,'kind':'photo','thumbnail_sha256':LocalMediaRepository.hash(jpeg),
  'thumbnail_bytes':jpeg.length,'width':1,'height':1,'duration_ms':0,'created_by':author,'sort_key':'${stamp}_photo'};
Json memory(String visibility,{String author=remote})=>{'family_id':fid,'created_by':author,'created_at':stamp,'updated_at':stamp,
  'title':'可见回忆','body':null,'mood':null,'location':null,'event_date':'2026-11-20','visibility':visibility};
Json memoryMedia(String parent,{String author=remote})=>{'memory_id':parent,'kind':'photo','thumbnail_sha256':LocalMediaRepository.hash(jpeg),
  'thumbnail_bytes':jpeg.length,'width':1,'height':1,'duration_ms':0,'created_by':author,'sort_key':'${stamp}_photo'};
Json op(int sequence,String suffix,String id,Json fields,{String scope=fid,String kind='patch',String actor=remote})=>
  {'space':scope,'collection':'/families/$scope/$suffix','id':id,'actor':actor,'sequence':sequence,'clock':sequence+100,'kind':kind,'fields':fields};
Json thumb(String id,{String scope=fid})=>{'space':scope,'id':id,'sha256':LocalMediaRepository.hash(jpeg),'bytes':base64Url.encode(jpeg)};
Json packet(List<Json> ops,{List<Json> thumbs=const[]})=>{'t':'delta','ops':ops,'thumbs':thumbs,'more':false};

void main(){
  sqfliteFfiInit();late Directory dir;late LocalStore store;late _CountMedia media;late _NoOriginal native;
  late _Registry registry;late TravelRoutes routes;late TravelSyncAdapter travel;late LocalIncrementalStrategy strategy;
  setUp(()async{
    dir=await Directory.systemTemp.createTemp('wo-travel-policy-');store=await LocalStore.open(factory:databaseFactoryFfi,path:'${dir.path}/local.sqlite');
    await store.patch(fid,'/families/$fid/members',store.deviceId,{'family_id':fid,'user_id':store.deviceId,'role':'owner','status':'active','display_name':'本机'});
    await store.patch(fid,'/families/$fid/members',remote,{'family_id':fid,'user_id':remote,'role':'member','status':'active','display_name':'远端'});
    native=_NoOriginal();media=_CountMedia(store,native:native,directory:Directory('${dir.path}/media'));await media.directory.create();
    registry=_Registry(store);routes=TravelRoutes(store,media:media,memories:MemoryRoutes(store,media:media,access:_Access()));travel=TravelSyncAdapter(routes);
    strategy=LocalIncrementalStrategy(store,registry,media,additionalSchemas:TravelRoutes.syncFields,travel:travel);
  });
  tearDown(()async{await store.close();await dir.delete(recursive:true);});
  Future<void> applyInactiveThumb(Json value)async{
    // 归属、描述和JPEG摘要已严格核验；仅父记录inactive时跳过安装，不阻塞其它合法日志。
    await strategy.apply(peer(),value);
  }

  test('同包descriptor先trip后使用finalshadow核权，只安装JPEG缩略图',()async{
    await strategy.apply(peer(),packet([
      op(1,'plugins/travel/media','photo-one',travelMedia('trip-one')),
      op(2,'plugins/travel/trips','trip-one',trip('photo-one')),
    ],thumbs:[thumb('photo-one')]));
    expect((await store.vector(fid))[remote],2);expect((await travel.descriptions(fid)).single['id'],'photo-one');
    expect(await File('${media.directory.path}/photo-one.jpg').readAsBytes(),jpeg);
    expect(await store.deviceReference('photo-one'),isNull);expect(native.reads,0);expect(native.prepared,0);
    expect((await dir.list(recursive:true).toList()).whereType<File>().where((f)=>f.path.contains('travel-artifacts-v1')),isEmpty);
  });
  test('本机源引用不会随出口ops或thumb发送，策略不prepare或读取原件',()async{
    const id='own-source';
    await store.patch(fid,'/families/$fid/plugins/travel/media',id,travelMedia('own-trip',author:store.deviceId));
    await store.patch(fid,'/families/$fid/plugins/travel/trips','own-trip',trip(id,author:store.deviceId));
    await store.saveDeviceReference(id,'photo',nativeHandle,{'scope':fid,'plugin':'travel','trip_id':'own-trip','memory_id':null,
      'thumbnail_sha256':LocalMediaRepository.hash(jpeg),'thumbnail_bytes':jpeg.length,'source_exact':false});
    await File('${media.directory.path}/$id.jpg').writeAsBytes(jpeg);
    final result=await strategy.delta(peer(),{'t':'state','vectors':{fid:<String,int>{}},'missing':<Json>[]});
    final wire=LocalStore.canonical(result);expect((result['thumbs'] as List),hasLength(1));
    expect(wire,isNot(contains(nativeHandle)));expect(wire,isNot(contains('source_exact')));expect(wire,isNot(contains('locator')));
    final bytes=base64Url.decode(((result['thumbs'] as List).single as Map)['bytes'] as String);expect(bytes,jpeg);
    expect(native.reads,0);expect(native.prepared,0);
  });
  test('p与c空间的旅行即使误列scope候选也拒绝整包',()async{
    for(final scope in ['p_private','c_partner']){
      registry.allowed={fid,scope};final before=await store.vector(fid);
      await expectLater(strategy.apply(peer(),packet([
        op(1,'plugins/travel/media','photo-$scope',travelMedia('trip-$scope'),scope:scope),
        op(2,'plugins/travel/trips','trip-$scope',trip('photo-$scope'),scope:scope),
      ])),throwsFormatException);
      expect(await store.vector(fid),before);expect(await store.list(scope,'/families/$scope/plugins/travel/media'),isEmpty);
    }
  });
  test('同包memory与travel重复媒体ID必须整包拒绝，finalshadow不提前落库',()async{
    final before=await store.vector(fid);
    await expectLater(strategy.apply(peer(),packet([
      op(1,'plugins/travel/media','collision',travelMedia('trip-one')),
      op(2,'plugins/memory/media','collision',memoryMedia('memory-one')),
      op(3,'plugins/travel/trips','trip-one',trip('collision')),
      op(4,'plugins/memory/memories','memory-one',memory('family')),
    ],thumbs:[thumb('collision')])),throwsFormatException);
    expect(await store.vector(fid),before);expect(await store.list(fid,'/families/$fid/plugins/travel/trips'),isEmpty);
    expect(await store.list(fid,'/families/$fid/plugins/memory/memories'),isEmpty);expect(await File('${media.directory.path}/collision.jpg').exists(),false);
  });
  test('同包跨family/couple scope重复媒体ID必须整包拒绝',()async{
    const couple='c_pair_ab';registry.allowed={fid,couple};final before=await store.vector(fid);
    await expectLater(strategy.apply(peer(),packet([
      op(1,'plugins/memory/media','collision',memoryMedia('family-memory')),
      op(1,'plugins/memory/media','collision',memoryMedia('couple-memory'),scope:couple),
      op(2,'plugins/memory/memories','family-memory',memory('family')),
      op(2,'plugins/memory/memories','couple-memory',memory('couple'),scope:couple),
    ])),throwsFormatException);
    expect(await store.vector(fid),before);expect(await store.vector(couple),isEmpty);
    expect(await store.list(fid,'/families/$fid/plugins/memory/media'),isEmpty);
  });
  test('孤立travel descriptor可推进日志，但无父thumb绝不安装',()async{
    await strategy.apply(peer(),packet([op(1,'plugins/travel/media','orphan',travelMedia('unknown-parent'))]));
    expect((await store.vector(fid))[remote],1);expect(await travel.descriptions(fid),isEmpty);
    await applyInactiveThumb(packet([op(2,'plugins/travel/trips','unrelated-trip',trip('unrelated-photo'))],thumbs:[thumb('orphan')]));
    expect((await store.vector(fid))[remote],2);expect(await store.get(fid,'/families/$fid/plugins/travel/trips','unrelated-trip'),isNotNull);
    expect(await File('${media.directory.path}/orphan.jpg').exists(),false);
    expect(native.reads,0);
  });
  test('先delete后birth空父墓碑保持惰性，旧thumb不复活内容',()async{
    await strategy.apply(peer(),packet([
      op(1,'plugins/travel/trips','never-born',{},kind:'delete'),
      op(2,'plugins/travel/media','late-photo',travelMedia('never-born')),
    ]));
    expect((await store.vector(fid))[remote],2);expect(await travel.descriptions(fid),isEmpty);
    await applyInactiveThumb(packet([],thumbs:[thumb('late-photo')]));expect(await File('${media.directory.path}/late-photo.jpg').exists(),false);
    expect(await store.get(fid,'/families/$fid/plugins/travel/trips','never-born'),isNull);
  });
  test('状态轮转不会让16个永久缺图饿死后续，每轮最多64文件探测/16请求',()async{
    await store.patch(fid,'/families/$fid/plugins/memory/memories','memory-one',memory('family',author:store.deviceId));
    for(var i=0;i<100;i++){
      final id='memory-${i.toString().padLeft(3,'0')}';
      await store.patch(fid,'/families/$fid/plugins/memory/media',id,memoryMedia('memory-one',author:store.deviceId));
      if(i>=16&&i<99)await File('${media.directory.path}/$id.jpg').writeAsBytes(jpeg);
    }
    final requested=<String>{};
    for(var round=0;round<10;round++){
      media.fileProbes=0;final state=await strategy.state(peer()),missing=(state['missing'] as List).cast<Map>();
      expect(media.fileProbes,lessThanOrEqualTo(64));expect(missing.length,lessThanOrEqualTo(16));requested.addAll(missing.map((v)=>v['id'] as String));
    }
    expect(requested,contains('memory-099'));expect(native.reads,0);expect(native.prepared,0);
  });
  test('坏旅行缩略图进入缺图修复而不使整轮state和游标失效',()async{
    await store.patch(fid,'/families/$fid/plugins/travel/media','corrupt-photo',travelMedia('corrupt-trip',author:store.deviceId));
    await store.patch(fid,'/families/$fid/plugins/travel/trips','corrupt-trip',trip('corrupt-photo',author:store.deviceId));
    await File('${media.directory.path}/corrupt-photo.jpg').writeAsBytes([0,1,2]);
    final state=await strategy.state(peer());
    expect((state['missing'] as List).map((v)=>(v as Map)['id']),contains('corrupt-photo'));
    expect(native.reads,0);expect(native.prepared,0);
  });
  test('本机受限ref绑定错误仍fail closed，不降级为missing请求',()async{
    await store.patch(fid,'/families/$fid/plugins/travel/media','bound-photo',travelMedia('bound-trip',author:store.deviceId));
    await store.patch(fid,'/families/$fid/plugins/travel/trips','bound-trip',trip('bound-photo',author:store.deviceId));
    await store.saveDeviceReference('bound-photo','photo',nativeHandle,{'scope':'p_private','plugin':'memory','memory_id':'secret-memory',
      'thumbnail_sha256':LocalMediaRepository.hash(jpeg),'thumbnail_bytes':jpeg.length});
    await File('${media.directory.path}/bound-photo.jpg').writeAsBytes(jpeg);
    await expectLater(strategy.state(peer()),throwsFormatException);
    await expectLater(strategy.delta(peer(),{'t':'state','vectors':{fid:<String,int>{}},'missing':<Json>[]}),throwsFormatException);
    expect(native.reads,0);expect(native.prepared,0);
  });
  test('缺图游标按peer隔离，第二台不会继承第一台的扫描前沿',()async{
    await store.patch(fid,'/families/$fid/plugins/memory/memories','memory-one',memory('family',author:store.deviceId));
    for(var i=0;i<40;i++)await store.patch(fid,'/families/$fid/plugins/memory/media','media-$i',memoryMedia('memory-one',author:store.deviceId));
    final first=await strategy.state(peer()),next=await strategy.state(peer()),other=await strategy.state(peer(id:secondLink));
    List<String> ids(Json s)=>(s['missing'] as List).map((m)=>(m as Map)['id'] as String).toList();
    expect(ids(first),isNot(ids(next)));expect(ids(other),ids(first));
  });
}
