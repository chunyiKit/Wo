// 已准备；未执行Dart/SDK/原生picker。所有字节合成，trusted目录由测试channel模拟。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/local/attachments/ordinary_attachment_store.dart';
import 'package:wo/local/backup/backup_models.dart';
import 'package:wo/local/transport/native_local.dart';

String digest(List<int> bytes)=>hashes.sha256.convert(bytes).toString();
class _Selection implements AttachmentSelectionSource {
  final payloads=<String,Uint8List>{},metadata=<String,AttachmentSelectionMetadata>{};
  final claimed=<String>{},released=<String>[];int counter=0,claimCount=0;
  AttachmentSelectionMetadata add(Uint8List bytes,{String purpose='chat_file_copy',String name='synthetic.pdf',String type='application/pdf'}){
    final token='00000000-0000-0000-0000-${(++counter).toString().padLeft(12,'0')}';
    final m=AttachmentSelectionMetadata(token:token,purpose:purpose,displayName:name,contentType:type,size:bytes.length,kind:purpose.endsWith('_image_copy')?'image':'file');
    payloads[token]=bytes;metadata[token]=m;return m;
  }
  @override Future<AttachmentSelectionMetadata?> pick({required String purpose})async=>metadata.values.where((v)=>v.purpose==purpose).firstOrNull;
  @override Future<AttachmentSelectionMetadata> claim({required String token,required String purpose})async{
    claimCount++;final m=metadata[token];if(m==null||m.purpose!=purpose||!claimed.add(token))throw const AttachmentException('selection_claim_denied');return m;
  }
  @override Future<Uint8List> read({required String token,required int offset,required int maxBytes})async{
    if(!claimed.contains(token)||maxBytes>ordinaryAttachmentChunkBytes)throw StateError('unclaimed or unbounded');
    final b=payloads[token]!;return Uint8List.sublistView(b,offset,(offset+maxBytes).clamp(offset,b.length).toInt());
  }
  @override Future<void> release(String token)async{released.add(token);metadata.remove(token);payloads.remove(token);}
}
void main(){
  TestWidgetsFlutterBinding.ensureInitialized();sqfliteFfiInit();
  const channel=MethodChannel('wo.test/ordinary-attachments');
  final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory base,private;late NativeCrypto crypto;late OrdinaryAttachmentStore store;late _Selection native;late int random;
  final binding=AttachmentBinding(familyId:'family-a',plugin:'chat',parentId:'message-a',authorDeviceId:'author-a');
  const firstId='a_11111111111111111111111111111111';
  final pdf=Uint8List.fromList(utf8.encode('%PDF-1.4\nsynthetic only'));
  final jpeg=Uint8List.fromList(base64Decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDzGiiiuw5T/9k='));
  Matcher error(String code)=>throwsA(isA<AttachmentException>().having((e)=>e.code,'code',code));
  AttachmentDescriptor descriptor(Uint8List bytes,{String id=firstId,AttachmentBinding? scope,String? sha})=>AttachmentDescriptor(
    id:id,binding:scope??binding,purpose:(scope?.plugin??binding.plugin)=='pet'?'pet_file_copy':'chat_file_copy',kind:'file',
    displayName:'synthetic.pdf',contentType:'application/pdf',size:bytes.length,sha256:sha??digest(bytes),createdAt:'2026-11-20T00:00:00Z');
  Future<OrdinaryAttachmentAsset> pick(Uint8List bytes,{String purpose='chat_file_copy',String name='synthetic.pdf',String type='application/pdf',String? id})async{
    final selection=native.add(bytes,purpose:purpose,name:name,type:type);return store.importSelection(selectionToken:selection.token,purpose:purpose,binding:binding,attachmentId:id);
  }
  Future<Uint8List> collect(BackupSource source)async{final b=BytesBuilder(copy:false);await for(final part in await source.openRange(0,source.entry.size)){b.add(part);}return b.takeBytes();}
  setUp(()async{
    base=await Directory.systemTemp.createTemp('wo-ordinary-attachments-');private=Directory('${base.path}/native-private');await private.create();native=_Selection();random=0;
    messenger.setMockMethodCallHandler(channel,(call)async{
      if(call.method=='privateDirectory'){expect((call.arguments as Map)['name'],OrdinaryAttachmentStore.privateDirectoryName);return private.path;}
      if(call.method=='random'){final count=(call.arguments as Map)['count'] as int;final n=++random;return Uint8List.fromList(List.generate(count,(i)=>(n+i)&255));}
      throw StateError('不得调用原件、相册或恢复接口');
    });
    crypto=NativeCrypto(channel:channel);store=await OrdinaryAttachmentStore.open(crypto:crypto,native:native,factory:databaseFactoryFfi);
  });
  tearDown(()async{await store.close();messenger.setMockMethodCallHandler(channel,null);await base.delete(recursive:true);});
  test('显式副本全文SHA、安全展示名不作路径、20MiB普通文件受限重备份',()async{
    final asset=await pick(pdf,name:'../../合成:文件.pdf');expect(asset.descriptor.displayName,contains('文件.pdf'));
    expect(asset.descriptor.displayName,not(contains('/')));expect(asset.descriptor.sha256,digest(pdf));expect(asset.available,true);
    expect(await store.read(binding,asset.id,offset:0),pdf);expect(native.claimCount,1);expect(native.released,hasLength(1));
    final source=await store.frozenBackupSource(binding,asset.id,entryId:'ordinary-file');
    expect(source.entry.kind,'file');expect(source.entry.sourceExact,false);expect(source.privacy,BackupPrivacy.restricted);expect(await collect(source),pdf);
  });
  test('同ID同绑定幂等、不重复claim；跨家庭/作者/父/插件绑定拒绝',()async{
    final asset=await pick(pdf,id:firstId);final retry=native.add(pdf);
    expect((await store.importSelection(selectionToken:retry.token,purpose:'chat_file_copy',binding:binding,attachmentId:firstId)).id,asset.id);expect(native.claimCount,1);
    for(final wrong in [AttachmentBinding(familyId:'other',plugin:'chat',parentId:'message-a',authorDeviceId:'author-a'),
      AttachmentBinding(familyId:'family-a',plugin:'chat',parentId:'other',authorDeviceId:'author-a'),
      AttachmentBinding(familyId:'family-a',plugin:'chat',parentId:'message-a',authorDeviceId:'other'),
      AttachmentBinding(familyId:'family-a',plugin:'pet',parentId:'message-a',authorDeviceId:'author-a')]){
      await expectLater(store.get(wrong,firstId),error('attachment_binding_conflict'));
      await expectLater(store.beginReceive(descriptor(pdf,scope:wrong)),error('attachment_binding_conflict'));
    }
  });
  test('不接受任意路径/原件handle借入，未知token失败且释放',()async{
    await expectLater(store.importSelection(selectionToken:'/private/photo.jpg',purpose:'chat_file_copy',binding:binding),error('invalid_attachment_token'));
    const unrelatedHandle='11111111-1111-1111-1111-111111111111';
    await expectLater(store.importSelection(selectionToken:unrelatedHandle,purpose:'chat_file_copy',binding:binding),error('selection_claim_denied'));
    expect(await store.list(binding),isEmpty);expect(native.released,contains(unrelatedHandle));
  });
  test('限额/目的/媒体伪普通文件不可发布',()async{
    expect(()=>descriptor(Uint8List(ordinaryAttachmentMaxBytes+1)),error('invalid_attachment_descriptor'));
    for(final media in [jpeg,Uint8List.fromList([137,80,78,71,0]),Uint8List.fromList([0,0,0,20,102,116,121,112,0])]){
      await expectLater(pick(media,name:'hidden.bin',type:'application/octet-stream'),error('media_requires_image_copy'));
    }
    await expectLater(pick(pdf,name:'hidden.jpg'),error('media_requires_image_copy'));expect(await store.list(binding),isEmpty);
  });
  test('图片只接规范JPEG1600内去meta，拒EXIF和超大尺寸',()async{
    final asset=await pick(jpeg,purpose:'chat_image_copy',name:'copy.jpg',type:'image/jpeg');expect(asset.available,true);
    final exif=Uint8List.fromList([...jpeg.take(2),255,225,0,8,69,120,105,102,0,0,...jpeg.skip(2)]);
    await expectLater(pick(exif,purpose:'chat_image_copy',name:'copy.jpg',type:'image/jpeg'),throwsA(anything));
    final large=Uint8List.fromList(jpeg);final marker=large.indexOf(192); // synthetic fixture SOF0 height follows marker+4
    large[marker+4]=6;large[marker+5]=65;expect(()=>validateAttachmentImage(large),throwsA(anything));
  });
  test('256KiB连续接收重启续传，相同分块幂等，全文SHA后发布',()async{
    final bytes=Uint8List.fromList(List.filled(300000,65)),d=descriptor(Uint8List.fromList(List.filled(300000,65)));
    expect((await store.beginReceive(d)).offset,0);
    final part=Uint8List.sublistView(bytes,0,ordinaryAttachmentChunkBytes);
    expect((await store.receiveChunk(d,offset:0,bytes:part)).available,false);
    await store.close();store=await OrdinaryAttachmentStore.open(crypto:crypto,native:native,factory:databaseFactoryFfi);
    expect((await store.beginReceive(d)).offset,ordinaryAttachmentChunkBytes);
    await store.receiveChunk(d,offset:0,bytes:part);
    await expectLater(store.receiveChunk(d,offset:ordinaryAttachmentChunkBytes+1,bytes:Uint8List.fromList([65])),error('attachment_offset_conflict'));
    final result=await store.receiveChunk(d,offset:ordinaryAttachmentChunkBytes,bytes:Uint8List.sublistView(bytes,ordinaryAttachmentChunkBytes));
    expect(result.available,true);expect((await store.verifiedFile(binding,d.id)).length(),completion(bytes.length));
  });
  test('完整SHA错误不发布，重试更换磁盘对象不覆盖失败文件',()async{
    final d=descriptor(pdf);await store.beginReceive(d);
    await expectLater(store.receiveChunk(d,offset:0,bytes:Uint8List.fromList(List.filled(pdf.length,65))),error('attachment_integrity'));
    expect((await store.get(binding,d.id))!.available,false);
    final before=await Directory('${private.path}/objects').list().toList();expect(before,hasLength(1));final failed=await File(before.single.path).readAsBytes();
    expect((await store.beginReceive(d)).offset,0);await store.receiveChunk(d,offset:0,bytes:pdf);
    expect(await File(before.single.path).readAsBytes(),failed);expect(await store.read(binding,d.id,offset:0),pdf);
  });
  test('flush后offset提交前断线只接同字节尾部，不覆盖冲突尾部',()async{
    final d=descriptor(pdf);await store.beginReceive(d);final file=File((await Directory('${private.path}/objects').list().toList()).single.path);
    await file.writeAsBytes(pdf.sublist(0,5),mode:FileMode.append,flush:true);
    await expectLater(store.receiveChunk(d,offset:0,bytes:Uint8List.fromList(List.filled(pdf.length,66))),error('attachment_offset_conflict'));
    expect(await file.readAsBytes(),pdf.sublist(0,5));expect((await store.receiveChunk(d,offset:0,bytes:pdf)).available,true);
  });
  test('同ID不同SHA/名字不可替换；接收缺口/过大chunk拒绝',()async{
    final d=descriptor(pdf);await store.beginReceive(d);
    await expectLater(store.beginReceive(descriptor(pdf,sha:List.filled(64,'0').join())),error('attachment_binding_conflict'));
    await expectLater(store.receiveChunk(d,offset:0,bytes:Uint8List(ordinaryAttachmentChunkBytes+1)),error('invalid_attachment_chunk'));
    expect((await store.get(binding,d.id))!.offset,0);
  });
  test('删除仅清本机副本、留缺件和原descriptor；不伪造已恢复完整',()async{
    final asset=await pick(pdf);await store.deleteLocal(binding,asset.id);
    expect((await store.get(binding,asset.id))!.status,'missing');expect((await store.list(binding)).single.descriptor.same(asset.descriptor),true);
    await expectLater(store.read(binding,asset.id,offset:0),error('attachment_unavailable'));
    expect((await store.frozenBackupSource(binding,asset.id)).entry.missing,'source_unavailable');
  });
  test('磁盘被改后read/图片访问/冻结source均校验全文，不发错误字节',()async{
    final asset=await pick(pdf),file=await store.verifiedFile(binding,(await store.list(binding)).single.id);
    final frozen=await store.frozenBackupSource(binding,asset.id);await file.writeAsBytes(List.filled(pdf.length,88),flush:true);
    await expectLater(store.read(binding,asset.id,offset:0),error('attachment_integrity'));
    await expectLater(collect(frozen),error('attachment_integrity'));
    expect((await store.frozenBackupSource(binding,asset.id)).entry.missing,'source_unavailable');
  });
  test('已发布副本后续损坏只轮换新对象恢复同SHA，不放松descriptor绑定',()async{
    final asset=await pick(pdf,id:firstId),file=await store.verifiedFile(binding,firstId);
    await file.writeAsBytes(List.filled(pdf.length,89),flush:true);
    final broken=await file.readAsBytes();expect((await store.beginReceive(asset.descriptor)).offset,0);
    await store.receiveChunk(asset.descriptor,offset:0,bytes:pdf);
    expect(await store.read(binding,firstId,offset:0),pdf);expect(await file.readAsBytes(),broken);
  });
  test('不跟随对象symlink且不把任意目录标作private',()async{
    final asset=await pick(pdf),file=await store.verifiedFile(binding,(await store.list(binding)).single.id);
    final outside=File('${base.path}/outside');await outside.writeAsBytes(pdf);await file.delete();await Link(file.path).create(outside.path);
    await expectLater(store.read(binding,asset.id,offset:0),error('unsafe_attachment_file'));
    await expectLater(store.beginReceive(asset.descriptor),error('unsafe_attachment_file'));expect(await outside.readAsBytes(),pdf);
  });
}
