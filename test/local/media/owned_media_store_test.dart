// 已准备但未执行Dart/Flutter/SDK；native目录通过测试channel模拟，不能证明OS保护/播放器通过。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/local/backup/backup_models.dart';
import 'package:wo/local/backup/portable_archive.dart';
import 'package:wo/local/media/owned_media_store.dart';
import 'package:wo/local/transport/native_local.dart';
import '../backup/mobile_backup_client_test.dart' show TestCrypto;

final thumbnail=Uint8List.fromList(base64Decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDzGiiiuw5T/9k='));
String sha(List<int> bytes)=>hashes.sha256.convert(bytes).toString();
class _Source extends BackupSource {
  _Source(String id,String kind,this.bytes,{bool exact=false}):entry=BackupEntry(id:id,kind:kind,size:bytes.length,sha256:sha(bytes),sourceExact:exact);
  final Uint8List bytes;@override final BackupEntry entry;
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async=>chunks(offset,length);
  Stream<List<int>> chunks(int offset,int length)async*{for(var at=offset;at<offset+length;at+=65536){yield bytes.sublist(at,at+65536>offset+length?offset+length:at+65536);}}
}
void main(){
  TestWidgetsFlutterBinding.ensureInitialized();sqfliteFfiInit();
  const workspace='new-private-workspace',channel=MethodChannel('wo.test/owned-media');
  final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory base,attested,staging;late OwnedMediaStore owned;late NativeCrypto native;
  late int counter;late Uint8List? forcedRandom;late List<String> calls;
  Matcher code(String value)=>throwsA(isA<OwnedMediaException>().having((e)=>e.code,'code',value));
  Future<PortableRestore> restore(List<_Source> sources,{List<PortableEntry> missing=const[]})async{
    final entries=[for(final s in sources)PortableEntry(id:s.entry.id,kind:s.entry.kind,size:s.entry.size,sha256:s.entry.sha256,sourceExact:s.entry.sourceExact),...missing];
    final manifest=PortableManifest(familyId:'old-archive-family',entries:entries);
    final archive=PortableArchive(TestCrypto());return archive.restoreToNewDirectory(archive.pack(manifest,{for(final s in sources)s.entry.id:s}),staging,expectedFamily:'old-archive-family');
  }
  Future<OwnedMediaAsset> adopt(PortableRestore archive,String entry,{String? thumbnailId,String? key})=>owned.importPortable(workspaceId:workspace,importKey:key??entry,restore:archive,entryId:entry,thumbnailId:thumbnailId);
  Future<Uint8List> collect(BackupSource source)async{final out=BytesBuilder(copy:false);await for(final bytes in await source.openRange(0,source.entry.size)){expect(bytes.length,lessThanOrEqualTo(65536));out.add(bytes);}return out.takeBytes();}
  setUp(()async{
    base=await Directory.systemTemp.createTemp('wo-owned-media-');attested=Directory('${base.path}/native-private');staging=Directory('${base.path}/verified-archives');await attested.create();await staging.create();
    counter=0;forcedRandom=null;calls=[];
    messenger.setMockMethodCallHandler(channel,(call)async{
      calls.add(call.method);
      if(call.method=='privateDirectory'){expect((call.arguments as Map)['name'],OwnedMediaStore.privateDirectoryName);return attested.path;}
      if(call.method=='random'){final count=(call.arguments as Map)['count'] as int;return forcedRandom??Uint8List.fromList(List.generate(count,(i)=>i==0?(++counter)&255:i));}
      throw StateError('新设备不应请求旧相册/Files/身份权限');
    });
    native=NativeCrypto(channel:channel);owned=await OwnedMediaStore.open(crypto:native,factory:databaseFactoryFfi);
  });
  tearDown(()async{await owned.close();messenger.setMockMethodCallHandler(channel,null);await base.delete(recursive:true);});

  test('新设备无Photos/Files权限，从归档字节创建新ownedID并复读重备份SHA相同',()async{
    const exifHex='45786966000049492a0008000000010025880400010000001a00000000000000040001000200020000004e000000020005000300000050000000030002000200000045000000040005000300000068000000000000001f000000010000000e000000010000000f0000000100000079000000010000001c000000010000001400000001000000';
    final exif=Uint8List.fromList(List.generate(exifHex.length~/2,(i)=>int.parse(exifHex.substring(i*2,i*2+2),radix:16)));
    final gps=Uint8List.fromList([...thumbnail.take(2),255,225,(exif.length+2)>>8,(exif.length+2)&255,...exif,...thumbnail.skip(2)]);
    final archive=await restore([_Source('old-photo','photo',gps,exact:true)]),asset=await adopt(await restore([_Source('old-photo','photo',gps,exact:true)]),'old-photo');
    expect(asset.id,startsWith('o_'));expect(asset.id,isNot(archive.files['old-photo']!.newId));expect(asset.id,isNot('old-photo'));expect(asset.sourceExact,true);
    expect(await owned.read(workspace,asset.id,offset:0),gps);final source=await owned.prepareBackupSource(workspace,asset.id);
    expect(source.entry.id,'old-photo');expect(source.entry.sha256,sha(gps));expect(source.entry.sourceExact,true);expect(source.privacy,BackupPrivacy.restricted);
    expect(sha(await collect(source)),sha(gps));expect(calls.toSet().difference({'privateDirectory','random'}),isEmpty);
    expect(asset.fullDeviceComplete,false);expect(asset.restricted,true);
  });
  test('records不解析原字节，备份可改新entryID而不重用旧身份',()async{
    final bytes=Uint8List.fromList(utf8.encode('{"schema":1,"text":"synthetic-only"}'));
    final archive=await restore([_Source('records-original','records',bytes)]),asset=await adopt(await restore([_Source('records-original','records',bytes)]),'records-original');
    final source=await owned.prepareBackupSource(workspace,asset.id,entryId:'records-remapped');expect(source.entry.id,'records-remapped');expect(await collect(source),bytes);
    expect(asset.kind,'records');expect(asset.sourceExact,false);expect(archive.recordsApplied,false);expect(await owned.list('old-archive-family'),isEmpty);
  });
  test('重启持久读取同一ownedID，不依赖旧源文件/书签/设备身份',()async{
    final bytes=Uint8List.fromList([1,2,3,4,5]),archive=await restore([_Source('photo','photo',Uint8List.fromList([1,2,3,4,5]),exact:true)]);
    final asset=await adopt(archive,'photo'),identity=owned.storeId;await owned.close();await owned.close();
    await archive.directory.delete(recursive:true);owned=await OwnedMediaStore.open(crypto:native,factory:databaseFactoryFfi);
    expect(owned.storeId,identity);expect((await owned.list(workspace)).single.id,asset.id);expect(await owned.read(workspace,asset.id,offset:0),bytes);
  });
  test('同importKey同清单幂等，不同字节冲突不覆盖已有原件',()async{
    final archive=await restore([_Source('photo','photo',Uint8List.fromList([4,5,6]),exact:true)]),asset=await adopt(await restore([_Source('photo','photo',Uint8List.fromList([4,5,6]),exact:true)]),'photo');
    expect((await adopt(archive,'photo')).id,asset.id);
    final changed=await restore([_Source('photo','photo',Uint8List.fromList([7,8,9]),exact:true)]);
    await expectLater(adopt(changed,'photo'),code('owned_import_conflict'));expect(await owned.read(workspace,asset.id,offset:0),[4,5,6]);
  });
  test('新ID碰撞拒绝而不截断或覆盖未索引文件',()async{
    final bytes=Uint8List.fromList(List.filled(16,66));forcedRandom=bytes;
    final collision='o_${bytes.map((v)=>v.toRadixString(16).padLeft(2,'0')).join()}',file=File('${attested.path}/objects/$collision.blob');
    await file.writeAsBytes([99,98,97]);final archive=await restore([_Source('photo','photo',Uint8List.fromList([1,2,3]),exact:true)]);
    await expectLater(adopt(archive,'photo'),code('owned_id_collision'));expect(await file.readAsBytes(),[99,98,97]);expect(await owned.list(workspace),isEmpty);
  });
  test('源完整性失败保留failed，修复后用新ID重试不覆盖失败对象',()async{
    final original=Uint8List.fromList([10,20,30,40]),archive=await restore([_Source('photo','photo',Uint8List.fromList([10,20,30,40]),exact:true)]);
    await archive.files['photo']!.file.writeAsBytes([9,9]);await expectLater(adopt(archive,'photo'),code('recovered_integrity'));
    final failed=(await owned.list(workspace)).single;expect(failed.available,false);final previous=File('${attested.path}/objects/${failed.id}.blob');expect(await previous.readAsBytes(),[9,9]);
    await archive.files['photo']!.file.writeAsBytes(original);final retry=await adopt(archive,'photo');expect(retry.id,isNot(failed.id));expect(retry.available,true);
    expect(await previous.readAsBytes(),[9,9]);expect(await owned.read(workspace,retry.id,offset:0),original);
  });
  test('正确SHA但非法JPEG缩略图失败后重试也不能发布ready',()async{
    final archive=await restore([_Source('invalid-thumbnail','thumbnail',Uint8List.fromList([1,2,3,4]))]);
    await expectLater(adopt(archive,'invalid-thumbnail'),code('invalid_owned_thumbnail'));
    expect((await owned.list(workspace)).single.available,false);
    await expectLater(adopt(archive,'invalid-thumbnail'),code('invalid_owned_thumbnail'));
    expect((await owned.list(workspace)).single.available,false);
  });
  test('缺原件保留新缩略图引用，不能冒充完整或exact原件',()async{
    final archive=await restore([_Source('thumb','thumbnail',thumbnail)],missing:[PortableEntry(id:'missing-video',kind:'video',size:0,sha256:'',sourceExact:false,missingReason:'source_unavailable')]);
    final thumb=await adopt(archive,'thumb'),missing=await adopt(archive,'missing-video',thumbnailId:thumb.id);
    expect(missing.available,false);expect(missing.thumbnailId,thumb.id);expect(missing.declaredBytesComplete,false);expect(await owned.verifiedFile(workspace,missing.id),isNull);
    expect(await owned.verifiedFile(workspace,thumb.id),isNotNull);final source=await owned.prepareBackupSource(workspace,missing.id);
    expect(source.entry.missing,'source_unavailable');expect(source.entry.size,0);expect(source.entry.sourceExact,false);
  });
  test('声明非exact原件保留字节但不提升保真状态',()async{
    final archive=await restore([_Source('photo','photo',Uint8List.fromList([7,6,5]),exact:false)]),asset=await adopt(await restore([_Source('photo','photo',Uint8List.fromList([7,6,5]),exact:false)]),'photo');
    expect(asset.available,true);expect(asset.sourceExact,false);expect(asset.declaredBytesComplete,false);expect(archive.declaredBytesComplete,false);
    expect((await owned.prepareBackupSource(workspace,asset.id)).entry.sourceExact,false);
  });
  test('跨workspace借用ownedID和缩略图均拒绝，不靠裸ID取文件',()async{
    final archive=await restore([_Source('thumb','thumbnail',thumbnail),_Source('photo','photo',Uint8List.fromList([2,3,4]),exact:true)]),thumb=await adopt(await restore([_Source('thumb','thumbnail',thumbnail)]),'thumb');
    expect(await owned.get('other-workspace',thumb.id),isNull);await expectLater(owned.verifiedFile('other-workspace',thumb.id),code('owned_not_found'));
    await expectLater(owned.importPortable(workspaceId:'other-workspace',importKey:'photo',restore:archive,entryId:'photo',thumbnailId:thumb.id),code('owned_not_found'));
    await expectLater(owned.prepareBackupSource('other-workspace',thumb.id),code('owned_not_found'));
  });
  test('源symlink与目标symlink/目录别名均拒绝，不读写外部对象',()async{
    final archive=await restore([_Source('photo','photo',Uint8List.fromList([4,3,2]),exact:true)]),outside=File('${base.path}/outside');await outside.writeAsBytes([4,3,2]);
    final source=archive.files['photo']!.file;await source.delete();await Link(source.path).create(outside.path);
    await expectLater(adopt(archive,'photo'),code('unsafe_recovered_source'));expect(await outside.readAsBytes(),[4,3,2]);
    await source.delete();await source.writeAsBytes([4,3,2]);final asset=await adopt(archive,'photo'),target=await owned.verifiedFile(workspace,asset.id);
    await target!.delete();await Link(target.path).create(outside.path);await expectLater(owned.verifiedFile(workspace,asset.id),code('owned_unavailable'));
    expect((await owned.prepareBackupSource(workspace,asset.id)).entry.missing,'source_unavailable');expect(await outside.readAsBytes(),[4,3,2]);
  });
  test('原件后续损坏不能重备份冒充完整，也不能幂等覆盖修复',()async{
    final archive=await restore([_Source('photo','photo',Uint8List.fromList([8,8,8]),exact:true)]),asset=await adopt(await restore([_Source('photo','photo',Uint8List.fromList([8,8,8]),exact:true)]),'photo');
    final file=await owned.verifiedFile(workspace,asset.id);await file!.writeAsBytes([0,0,0]);
    expect((await owned.prepareBackupSource(workspace,asset.id)).entry.missing,'source_unavailable');await expectLater(adopt(archive,'photo'),code('owned_integrity'));expect(await file.readAsBytes(),[0,0,0]);
  });
  test('大合成video流范围和再次打包摘要保持一致，不以模拟字节冒充HDR播放验证',()async{
    final bytes=Uint8List.fromList(List.generate(9*1024*1024+17,(i)=>(i*13)&255)),archive=await restore([_Source('video','video',Uint8List.fromList(List.generate(9*1024*1024+17,(i)=>(i*13)&255)),exact:true)]);
    final asset=await adopt(archive,'video');expect(await owned.read(workspace,asset.id,offset:bytes.length-5,maxBytes:5),bytes.sublist(bytes.length-5));
    await expectLater(owned.read(workspace,asset.id,offset:0,maxBytes:OwnedMediaStore.maxReadBytes+1),code('owned_read_limit'));
    final source=await owned.prepareBackupSource(workspace,asset.id);expect(sha(await collect(source)),sha(bytes));
    final packed=PortableArchive(TestCrypto()).pack(PortableManifest(familyId:'new-private-family',entries:archive.manifest.entries),{'video':source});
    final reread=await PortableArchive(TestCrypto()).restoreToNewDirectory(packed,staging,expectedFamily:'new-private-family');
    expect(sha(await reread.files['video']!.file.readAsBytes()),sha(bytes));expect(reread.fullDeviceComplete,false);
  });
}
