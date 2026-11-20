import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/local/backup/backup_models.dart';
import 'package:wo/local/local_media_repository.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/media/native_media.dart';
import 'package:wo/local/plugins/memory_routes.dart';
import 'package:wo/local/plugins/travel_routes.dart';
import 'package:wo/local/sync/travel_sync_adapter.dart';
class _Access implements MemoryAccess {
  @override Future<List<String>> visibleSpaces(String fid)async=>[fid];
  @override Future<String> spaceFor(String fid,String visibility)async=>fid;
}
class _Bytes extends BackupSource {
  _Bytes(String id,this.privacy):entry=BackupEntry(id:id,kind:'photo',size:3,sha256:LocalMediaRepository.hash([1,2,3]),sourceExact:true);
  @override final BackupEntry entry;
  @override final BackupPrivacy privacy;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async=>Stream.value([1,2,3].sublist(offset,offset+length));
}
class _Media extends LocalMediaRepository {
  _Media(LocalStore store,{required Directory directory}):super(store,native:NativeMedia(),directory:directory);
  int prepared=0;
  @override Future<BackupSource> prepareBackupSource(String id,{required BackupPrivacy privacy,String kindIfMissing='photo'})async{prepared++;return _Bytes(id,privacy);}
}
final jpeg=Uint8List.fromList(base64Decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDzGiiiuw5T/9k='));
void main(){
  sqfliteFfiInit();const fid='family',trip='trip-one',original='original-one';
  late Directory dir;late LocalStore store;late _Media media;late TravelRoutes routes;late TravelSyncAdapter adapter;
  Json tripRow(String id,String photo)=>{'id':id,'family_id':fid,'created_by':store.deviceId,'created_at':'2026-11-20T00:00:00.000Z',
    'updated_at':'2026-11-20T00:00:00.000Z','city_name':'杭州','city_lng':120.1,'city_lat':30.2,'original_media_id':photo,'display_media_id':photo,'ai_status':'none','memory_id':null};
  Json descriptor(String parent)=>{'trip_id':parent,'kind':'photo','thumbnail_sha256':LocalMediaRepository.hash(jpeg),'thumbnail_bytes':jpeg.length,
    'width':16,'height':16,'duration_ms':0,'created_by':store.deviceId,'sort_key':'2026-11-20T00:00:00.000Z_photo'};
  Future<void> put(String collection,String id,Json data)async{await store.patch(fid,'/families/$fid/plugins/travel/$collection',id,{for(final e in data.entries)if(e.key!='id')e.key:e.value});}
  Json op(String collection,String id,Json fields)=>{'space':fid,'collection':'/families/$fid/plugins/travel/$collection','id':id,'actor':store.deviceId,'kind':'patch','fields':fields};
  setUp(()async{
    dir=await Directory.systemTemp.createTemp('wo-travel-adapter-');store=await LocalStore.open(factory:databaseFactoryFfi,path:'${dir.path}/local.sqlite');
    await store.patch(fid,'/families/$fid/members',store.deviceId,{'family_id':fid,'user_id':store.deviceId,'status':'active','role':'owner'});
    media=_Media(store,directory:Directory('${dir.path}/media'));await media.directory.create();
    routes=TravelRoutes(store,media:media,memories:MemoryRoutes(store,media:media,access:_Access()));adapter=TravelSyncAdapter(routes);
    await put('trips',trip,tripRow(trip,original));await put('media',original,descriptor(trip));await File('${media.directory.path}/$original.jpg').writeAsBytes(jpeg);
    await store.saveDeviceReference(original,'photo','00000000-0000-4000-8000-000000000002',{'scope':fid,'plugin':'travel','trip_id':trip,'memory_id':null});
  });
  tearDown(()async{await store.close();await dir.delete(recursive:true);});
  test('只枚举活跃旅行真正引用的descriptor，孤立和删除内容不输出',()async{
    await put('media','orphan-photo',descriptor('unknown-trip'));expect((await adapter.descriptions(fid)).map((d)=>d['id']),[original]);
    await store.patch(fid,'/families/$fid/plugins/travel/trips',trip,{},delete:true);expect(await adapter.descriptions(fid),isEmpty);
  });
  test('整包pending lookup支持父trip和descriptor尚未merge',()async{
    final parent=tripRow('pending-trip','pending-photo'),desc={'id':'pending-photo',...descriptor('pending-trip')};
    Future<Json?> pending(String s,String c,String id)async=>id=='pending-trip'?parent:id=='pending-photo'?desc:adapter.lookup(s,c,id);
    await adapter.validateOp(op('media','pending-photo',descriptor('pending-trip')),lookup:pending);
    await adapter.validateOp(op('trips','pending-trip',{for(final e in parent.entries)if(e.key!='id')e.key:e.value}),lookup:pending);
    await adapter.validateThumbnail(fid,'pending-photo',LocalMediaRepository.hash(jpeg),jpeg,lookup:pending);
    expect(await store.get(fid,'/families/$fid/plugins/travel/trips','pending-trip'),isNull);
  });
  test('分页先到孤立descriptor可惰性保存，但不能先接收或发送thumb',()async{
    final desc=descriptor('unknown-trip');await adapter.validateOp(op('media','orphan-photo',desc),lookup:adapter.lookup);
    await put('media','orphan-photo',desc);expect(await adapter.thumbnailForWire(fid,'orphan-photo'),isNull);
    await expectLater(adapter.validateThumbnail(fid,'orphan-photo',LocalMediaRepository.hash(jpeg),jpeg,lookup:adapter.lookup),throwsFormatException);
  });
  test('thumb要求最终alive引用，pending tombstone不读取旧像素',()async{
    Future<Json?> deleted(String s,String c,String id)async{final row=await adapter.lookup(s,c,id);return id==trip?{...row!,'_deleted':true}:row;}
    await expectLater(adapter.validateThumbnail(fid,original,LocalMediaRepository.hash(jpeg),jpeg,lookup:deleted),throwsFormatException);
    final wire=await adapter.thumbnailForWire(fid,original);expect(wire!.keys.toSet(),{'space','id','sha256','bytes'});expect(base64Url.decode(wire['bytes'] as String),jpeg);expect(media.prepared,0);
  });
  test('原件字段与受限关联拒绝，父绑定不可变',()async{
    await expectLater(adapter.validateOp(op('media',original,{...descriptor(trip),'original_bytes':[1]}),lookup:adapter.lookup),throwsFormatException);
    await expectLater(adapter.validateOp(op('trips',trip,{'memory_id':'private-memory'}),lookup:adapter.lookup),throwsFormatException);
    await expectLater(adapter.validateOp(op('media',original,{'trip_id':'other-trip'}),lookup:adapter.lookup,previous:{'id':original,...descriptor(trip)}),throwsFormatException);
  });
  test('备份包含原照及全部artifact，远端原件明确缺件，thumb另编号',()async{
    for(final id in ['old-artifact','preview-failed'])await put('artifacts',id,{'trip_id':trip,'kind':'photo','created_by':store.deviceId,'created_at':'2026-11-20T00:00:00.000Z','thumbnail_ready':id=='old-artifact'});
    await put('media','old-artifact',descriptor(trip));await File('${media.directory.path}/old-artifact.jpg').writeAsBytes(jpeg);
    final sources=await adapter.backupSources(fid,privacy:BackupPrivacy.restricted);expect(sources,hasLength(5));expect(media.prepared,1);
    final originals=sources.where((s)=>s.entry.kind=='photo').toList();expect(originals,hasLength(3));expect(originals.where((s)=>s.entry.missing=='source_unavailable'),hasLength(2));
    expect(sources.every((s)=>s.privacy==BackupPrivacy.restricted),isTrue);expect(sources.where((s)=>s.entry.kind=='thumbnail'),hasLength(2));
    expect(TravelSyncAdapter.thumbnailBackupId(fid,'x'*100).length,lessThanOrEqualTo(100));
  });
  test('本机私密引用碰撞在备份prepare之前失败，不读原件',()async{
    await store.saveDeviceReference(original,'photo','00000000-0000-4000-8000-000000000002',{'scope':'p_private','memory_id':'secret','plugin':'memory'});
    await expectLater(adapter.backupSources(fid),throwsFormatException);expect(media.prepared,0);
  });
}
