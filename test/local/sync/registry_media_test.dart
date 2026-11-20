// 已准备，当前轮禁止执行 Dart/Flutter；此文件不代表移动端验收通过。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/local_media_repository.dart';
import 'package:wo/local/media/native_media.dart';
import 'package:wo/local/sync/peer_registry.dart';
import 'package:wo/local/transport/native_local.dart';

class _Crypto implements LocalCrypto {
  final secrets=<String,Uint8List>{};int writes=0,counter=0;
  @override Future<Uint8List> random(int count) async=>Uint8List.fromList(List.generate(count,(i)=>(i+counter++)&255));
  @override Future<void> putSecret(String handle,Uint8List bytes) async {writes++;secrets[handle]=Uint8List.fromList(bytes);}
  @override Future<Uint8List?> getSecret(String handle) async=>secrets[handle]==null?null:Uint8List.fromList(secrets[handle]!);
  @override Future<void> deleteSecret(String handle) async {secrets.remove(handle);}
  @override Future<Uint8List> hash(Uint8List bytes)=>throw UnimplementedError();
  @override Future<Uint8List> hmac({required Uint8List key,required Uint8List data})=>throw UnimplementedError();
  @override Future<Uint8List> seal({required Uint8List key,required Uint8List nonce,required Uint8List plaintext,required Uint8List aad})=>throw UnimplementedError();
  @override Future<Uint8List> open({required Uint8List key,required Uint8List nonce,required Uint8List ciphertext,required Uint8List aad})=>throw UnimplementedError();
}
const fid='family-test',id1='11111111-1111-4111-8111-111111111111',id2='22222222-2222-4222-8222-222222222222';
final jpeg=Uint8List.fromList(base64.decode('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESUM8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDzGiiiuw5T/9k='));
Future<void> member(LocalStore s,String device,String role,{String status='active'}) async {
  await s.patch(fid,'/families/$fid/members',device,{'family_id':fid,'user_id':device,'role':role,'status':status});
}
Future<void> family(LocalStore s,String role) async {
  await s.patch(fid,'/families/$fid/family',fid,{'name':'合成家庭'});await member(s,s.deviceId,role);
}
PeerLink link(String id,String remote,{String familyId=fid,String role='member'})=>PeerLink(
  id:id,familyId:familyId,remoteDeviceId:remote,secretRef:'wo.sync.link.$id',remoteRole:role);
PairInvitation invitation(String id,String remote,{String familyId=fid,String role='owner'})=>PairInvitation(
  id,familyId,remote,Uint8List.fromList(List.filled(32,11)),DateTime.now().millisecondsSinceEpoch+60000,'合成家庭',role:role);

void main(){
  sqfliteFfiInit();late Directory temp;late LocalStore a,b;late _Crypto ca,cb;late PeerRegistry ra,rb;
  setUp(()async{temp=await Directory.systemTemp.createTemp('wo-registry-media-');
    a=await LocalStore.open(factory:databaseFactoryFfi,path:'${temp.path}/a.sqlite');
    b=await LocalStore.open(factory:databaseFactoryFfi,path:'${temp.path}/b.sqlite');
    ca=_Crypto();cb=_Crypto();ra=PeerRegistry(a,ca);rb=PeerRegistry(b,cb);});
  tearDown(()async{await a.close();await b.close();await temp.delete(recursive:true);});

  test('邀请严格8字段、UUID、全长ID和URL-safe NoPad；重复JSON键拒绝',(){
    final encoded=invitation(id1,'remote').encode(),parsed=PairInvitation.parse(encoded);expect(parsed.role,'owner');
    final raw=utf8.decode(un64(encoded.substring('wo-local-pair:v1:'.length)));
    expect((jsonDecode(raw) as Map).length,8);
    expect(()=>PairInvitation.parse('wo-local-pair:v1:${wire64(utf8.encode(raw.replaceFirst('"v":1','"v":1,"v":1')))}'),throwsFormatException);
    expect(()=>invitation('abc','remote').encode(),throwsFormatException);
    expect(()=>invitation(id1,'remote\n').encode(),throwsFormatException);
    expect(()=>invitation(id1,'remote',familyId:'p_private').encode(),throwsFormatException);
    expect(()=>invitation(id1,'remote',familyId:'c_couple').encode(),throwsFormatException);
    for(final raw in ['Zg=','Zg==','Zg\n','Z+','Z/','Zh','']){expect(()=>un64(raw),throwsFormatException);}
    expect(un64('Zg'),[102]);
  });
  test('有效普通成员只可与同家已有成员逐对配对；新家庭只准owner引入',()async{
    await family(a,'owner');await family(b,'member');await member(a,b.deviceId,'member');await member(b,a.deviceId,'owner');
    final qr=await rb.createInvitation(fid);expect(qr.role,'member');
    final accepted=await ra.accept(PairInvitation.parse(qr.encode()));expect(accepted.remoteRole,'member');
    final responder=await rb.lookup(qr.linkId,a.deviceId);expect(responder!.remoteRole,'owner');
    await rb.authenticated(responder);await ra.authenticated(accepted);
    expect(await ra.scopes(accepted),{fid});expect(await rb.scopes(responder),{fid});
    await expectLater(ra.accept(invitation(id2,'unknown',role:'member',familyId:'new-family')),throwsFormatException);
  });
  test('两个对端并发消费同一邀请只有一个获权，第二条同设备连接幂等',()async{
    await family(a,'owner');final qr=await ra.createInvitation(fid);
    final one=(await ra.lookup(qr.linkId,'remote-one'))!,two=(await ra.lookup(qr.linkId,'remote-two'))!;
    Future<bool> attempt(PeerLink p)async{try{await ra.authenticated(p);return true;}on FormatException{return false;}}
    final results=await Future.wait([attempt(one),attempt(two)]);expect(results.where((v)=>v),hasLength(1));
    final winner=(await ra.links()).single;expect(await a.privateValue('sync-invite:${qr.linkId}'),isNull);
    expect(await a.get(fid,'/families/$fid/members',winner.remoteDeviceId),isNotNull);
    final loser=winner.remoteDeviceId=='remote-one'?'remote-two':'remote-one';expect(await a.get(fid,'/families/$fid/members',loser),isNull);
    await ra.authenticated(winner);expect(await ra.links(),hasLength(1));
  });
  test('活跃/撤销/pending ID碰撞均在写secret前拒绝，不覆盖旧授权',()async{
    await ra.save(link(id1,'remote'));await ca.putSecret('wo.sync.link.$id1',Uint8List.fromList([1,2,3]));
    final before=ca.writes;
    await expectLater(ra.accept(invitation(id1,'different',familyId:'different-family')),throwsFormatException);
    expect(ca.writes,before);expect(ca.secrets['wo.sync.link.$id1'],[1,2,3]);
    await ra.revoke(id1);await expectLater(ra.accept(invitation(id1,'different')),throwsFormatException);expect(ca.writes,before);
    await family(a,'owner');final pending=await ra.createInvitation(fid),writes=ca.writes;
    await expectLater(ra.accept(invitation(pending.linkId,'different')),throwsFormatException);expect(ca.writes,writes);
  });
  test('跨实例save不丢记录，双方couple同意并发不丢标记，scope不信传入快照',()async{
    await family(a,'owner');await member(a,'remote-one','member');await member(a,'remote-two','member');
    final one=link(id1,'remote-one'),two=link(id2,'remote-two');
    await Future.wait([ra.save(one),PeerRegistry(a,ca).save(two)]);expect(await ra.links(),hasLength(2));
    await Future.wait([ra.coupleConsent(id1,local:true),ra.coupleConsent(id1,remote:true)]);
    expect(await ra.scopes(one),{fid,one.coupleSpace});
    await expectLater(ra.scopes(link(id1,'remote-one',familyId:'other')),throwsFormatException);
    await expectLater(ra.scopes(link(id1,'remote-one',role:'owner')),throwsFormatException);
    await member(a,'remote-one','member',status:'removed');await expectLater(ra.scopes(one),throwsFormatException);
    await ra.revoke(id2);await expectLater(ra.scopes(two),throwsFormatException);
  });
  test('完整JPEG允许小图，拒绝首SOS后APP1/COM、截断扫描和EOI尾巴',(){
    expect(()=>LocalMediaRepository.validateThumbnail(jpeg),returnsNormally);
    expect(()=>LocalMediaRepository.validateThumbnail(Uint8List.fromList(jpeg.sublist(0,jpeg.length-2))),throwsFormatException);
    expect(()=>LocalMediaRepository.validateThumbnail(Uint8List.fromList([...jpeg,1,2,3])),throwsFormatException);
    for(final marker in [225,254]){
      final injected=Uint8List.fromList([...jpeg.sublist(0,jpeg.length-2),255,marker,0,6,71,80,83,0,255,217]);
      expect(()=>LocalMediaRepository.validateThumbnail(injected),throwsFormatException);
    }
    expect(()=>LocalMediaRepository.validateThumbnail(Uint8List.fromList([255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,255,218])),throwsFormatException);
  });
  test('媒体排序不随revision或不同增量到达顺序跳动，旧行按id稳定',()async{
    final repo=LocalMediaRepository(a,native:NativeMedia(),directory:Directory('${temp.path}/media'));
    final collection='/families/$fid/plugins/memory/media';
    Map<String,dynamic> fields(String sort)=>{'kind':'photo','memory_id':'memory','thumbnail_sha256':LocalMediaRepository.hash(jpeg),'thumbnail_bytes':jpeg.length,if(sort.isNotEmpty)'sort_key':sort};
    await a.patch(fid,collection,'second',fields('2026-01-02_second'));
    await a.patch(fid,collection,'first',fields('2026-01-01_first'));
    expect((await repo.forMemory(fid,'memory')).map((e)=>e.id),['first','second']);
    await a.patch(fid,collection,'first',{'width':24});
    expect((await repo.forMemory(fid,'memory')).map((e)=>e.id),['first','second']);
    await a.patch(fid,collection,'old-z',fields(''));await a.patch(fid,collection,'old-a',fields(''));
    final order=(await repo.forMemory(fid,'memory')).map((e)=>e.id).toList();expect(order.indexOf('old-a'),lessThan(order.indexOf('old-z')));
  });
  test('缩略图须先有当前scope的descriptor，坏文件重传修复且不碰原件',()async{
    final dir=Directory('${temp.path}/media');await dir.create();final repo=LocalMediaRepository(a,native:NativeMedia(),directory:dir);
    final sha=LocalMediaRepository.hash(jpeg);
    await expectLater(repo.receiveThumbnail(fid,'thumb',sha,jpeg),throwsFormatException);
    await a.patch(fid,'/families/$fid/plugins/memory/media','thumb',{'kind':'photo','memory_id':'memory','thumbnail_sha256':sha,'thumbnail_bytes':jpeg.length});
    await expectLater(repo.receiveThumbnail('other','thumb',sha,jpeg),throwsFormatException);
    await expectLater(repo.receiveThumbnail('p_private','thumb',sha,jpeg),throwsFormatException);
    final original=File('${dir.path}/original.bin');await original.writeAsBytes([1,2,3,4]);
    await File('${dir.path}/thumb.jpg').writeAsBytes([0,1,2]);
    await Future.wait([repo.receiveThumbnail(fid,'thumb',sha,jpeg),repo.receiveThumbnail(fid,'thumb',sha,jpeg)]);
    expect(await File('${dir.path}/thumb.jpg').readAsBytes(),jpeg);expect(await original.readAsBytes(),[1,2,3,4]);
    expect((await dir.list().toList()).where((f)=>f.path.contains('.corrupt-')),hasLength(1));
    expect((await repo.thumbnailForWire(fid,'thumb'))!['sha256'],sha);
    await a.patch(fid,'/families/$fid/plugins/memory/media','thumb',{},delete:true);
    await expectLater(repo.receiveThumbnail(fid,'thumb',sha,jpeg),throwsFormatException);
  });
  test('两成员remote-only伴侣缩略图ID不能被全家descriptor重挂',()async{
    const couple='c_pair_ab',mediaId='remote-only-couple';final sha=LocalMediaRepository.hash(jpeg);
    final dir=Directory('${temp.path}/b-media');await dir.create();
    final repo=LocalMediaRepository(b,native:NativeMedia(),directory:dir);
    await a.patch(couple,'/families/$couple/plugins/memory/media',mediaId,{'kind':'photo','memory_id':'secret-memory','thumbnail_sha256':sha,'thumbnail_bytes':jpeg.length});
    await b.merge(couple,await a.exportSince(couple,{}));
    expect(a.deviceId,isNot(b.deviceId));expect(await b.deviceReference(mediaId),isNull);
    await repo.receiveThumbnail(couple,mediaId,sha,jpeg);
    await a.patch(fid,'/families/$fid/plugins/memory/media',mediaId,{'kind':'photo','memory_id':'family-memory','thumbnail_sha256':sha,'thumbnail_bytes':jpeg.length});
    await b.merge(fid,await a.exportSince(fid,{}));
    await expectLater(repo.thumbnailForWire(fid,mediaId),throwsFormatException);
    await expectLater(repo.receiveThumbnail(fid,mediaId,sha,jpeg),throwsFormatException);
    expect(await File('${dir.path}/$mediaId.jpg').readAsBytes(),jpeg);
  });
  test('远端伴侣媒体墓碑仍保留归属，fresh本机引用也不能借ID改绑',()async{
    const couple='c_pair_ab',mediaId='deleted-couple-thumb';final sha=LocalMediaRepository.hash(jpeg);
    final dir=Directory('${temp.path}/b-media');await dir.create();final repo=LocalMediaRepository(b,native:NativeMedia(),directory:dir);
    final collection='/families/$couple/plugins/memory/media';
    await a.patch(couple,collection,mediaId,{'kind':'photo','memory_id':'secret-memory','thumbnail_sha256':sha,'thumbnail_bytes':jpeg.length});
    await b.merge(couple,await a.exportSince(couple,{}));await repo.receiveThumbnail(couple,mediaId,sha,jpeg);
    await a.patch(couple,collection,mediaId,{},delete:true);await b.merge(couple,await a.exportSince(couple,await b.vector(couple)));
    expect(await b.get(couple,collection,mediaId),isNull);expect(await b.deviceReference(mediaId),isNull);
    await b.saveDeviceReference(mediaId,'photo',id1,{'kind':'photo','scope':null,'memory_id':null,'thumbnail_sha256':sha,'thumbnail_bytes':jpeg.length,'selected_at':'2026-11-20T00:00:00.000Z'});
    await expectLater(repo.attach(fid,'new-family-memory',mediaId),throwsFormatException);
    expect(jsonDecode((await b.deviceReference(mediaId))!['metadata'] as String)['scope'],isNull);
    await a.patch(fid,'/families/$fid/plugins/memory/media',mediaId,{'kind':'photo','memory_id':'new-family-memory','thumbnail_sha256':sha,'thumbnail_bytes':jpeg.length});await b.merge(fid,await a.exportSince(fid,{}));
    await expectLater(repo.thumbnailForWire(fid,mediaId),throwsFormatException);
    await expectLater(repo.receiveThumbnail(fid,mediaId,sha,jpeg),throwsFormatException);
    expect(await File('${dir.path}/$mediaId.jpg').readAsBytes(),jpeg);
  });
  test('当前descriptor也须匹配本机父记录，旅行墓碑不能复用成回忆',()async{
    final dir=Directory('${temp.path}/media');await dir.create();final repo=LocalMediaRepository(a,native:NativeMedia(),directory:dir),sha=LocalMediaRepository.hash(jpeg);
    await a.patch(fid,'/families/$fid/plugins/memory/media','local-thumb',{'kind':'photo','memory_id':'one','thumbnail_sha256':sha,'thumbnail_bytes':jpeg.length});
    await a.saveDeviceReference('local-thumb','photo',id1,{'scope':fid,'memory_id':'other','thumbnail_sha256':sha});
    await expectLater(repo.receiveThumbnail(fid,'local-thumb',sha,jpeg),throwsFormatException);
    await expectLater(repo.thumbnailForWire(fid,'local-thumb'),throwsFormatException);
    await a.patch(fid,'/families/$fid/plugins/travel/media','travel-thumb',{},delete:true);
    await a.patch(fid,'/families/$fid/plugins/memory/media','travel-thumb',{'kind':'photo','memory_id':'one','thumbnail_sha256':sha,'thumbnail_bytes':jpeg.length});
    await expectLater(repo.receiveThumbnail(fid,'travel-thumb',sha,jpeg),throwsFormatException);
  });
  test('并发跨实例attach同一fresh媒体只能绑定一个权限空间',()async{
    final dir=Directory('${temp.path}/media');await dir.create();
    final one=LocalMediaRepository(a,native:NativeMedia(),directory:dir),two=LocalMediaRepository(a,native:NativeMedia(),directory:dir),sha=LocalMediaRepository.hash(jpeg);
    await a.saveDeviceReference('fresh-thumb','photo',id1,{'kind':'photo','scope':null,'memory_id':null,'thumbnail_sha256':sha,'thumbnail_bytes':jpeg.length,'selected_at':'2026-11-20T00:00:00.000Z'});
    Future<bool> attempt(LocalMediaRepository repo,String scope)async{try{await repo.attach(scope,'memory','fresh-thumb');return true;}on FormatException{return false;}}
    final results=await Future.wait([attempt(one,fid),attempt(two,'c_pair_ab')]);expect(results.where((v)=>v),hasLength(1));
    final rows=await a.db.query('documents',where:'id=?',whereArgs:['fresh-thumb']);expect(rows,hasLength(1));
    final meta=jsonDecode((await a.deviceReference('fresh-thumb'))!['metadata'] as String) as Map;expect(meta['scope'],rows.single['space']);expect(meta['memory_id'],'memory');
  });

}
