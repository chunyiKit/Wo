import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/local/backup/backup_models.dart';
import 'package:wo/local/backup/backup_transport.dart';
import 'package:wo/local/backup/mobile_backup_controller.dart';
import 'mobile_backup_client_test.dart' show TestCrypto,FakeTransport,jsonReply;

class MemoryPreferences implements BackupPreferencesStore {
  Map<String,dynamic>? data;
  @override Future<Map<String,dynamic>?> read()async=>data==null?null:jsonDecode(jsonEncode(data)) as Map<String,dynamic>;
  @override Future<void> write(Map<String,dynamic> value)async{data=jsonDecode(jsonEncode(value)) as Map<String,dynamic>;}
}
/// 仅控制器流程测试答案，不是AES实现；真实字节契约由独立Go oracle验证。
class ControllerCrypto extends TestCrypto {
  int seals=0;
  @override Future<Uint8List> seal({required Uint8List key,required Uint8List nonce,required Uint8List plaintext,required Uint8List aad})async{
    seals++;return Uint8List.fromList(List.filled(plaintext.length+16,0x77));
  }
}
class LocalSource implements BackupSource {
  LocalSource(String id,this.bytes,{String kind='records',this.privacy=BackupPrivacy.public,bool exact=false,String missing=''})
    :entry=BackupEntry(id:id,kind:kind,size:bytes.length,sha256:missing.isEmpty?hashes.sha256.convert(bytes).toString():'',sourceExact:exact,missing:missing);
  final Uint8List bytes;@override final BackupEntry entry;@override final BackupPrivacy privacy;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async=>Stream.value(Uint8List.sublistView(bytes,offset,offset+length));
}
class ComputerDouble {
  ComputerDouble(){transport.handle=handle;}
  final transport=FakeTransport();BackupManifest? manifest;final offsets=<String,int>{};bool loseFirstAck=false;
  final puts=<String>[];
  Future<BackupReply> handle(String method,String path,Map<String,String> headers,Uint8List? body)async{
    if(path=='/v1/pair'){
      final j=jsonDecode(utf8.decode(body!)) as Map<String,dynamic>;return jsonReply({'token':'4'*64,'family':j['family'],'device':j['device']},status:201);
    }
    if(path=='/v1/backups'&&method=='POST'){
      final next=BackupManifest.fromJson(backupObject(jsonDecode(utf8.decode(body!))));
      if(manifest!=null)expect(next.canonicalJson,manifest!.canonicalJson);manifest=next;return jsonReply({'ok':true},status:201);
    }
    if(path=='/v1/backups'&&method=='GET')return jsonReply([]);
    final m=manifest!;
    if(method=='PUT'){
      final uri=Uri.parse(path),id=Uri.parse(path).pathSegments.last;puts.add(id);
      final start=int.parse(uri.queryParameters['offset']!);expect(hashes.sha256.convert(body!).toString(),headers['X-Chunk-SHA256']);offsets[id]=start+body.length;
      if(loseFirstAck){loseFirstAck=false;throw const BackupException('lost_ack',retryable:true);}return jsonReply({'offset':offsets[id]});
    }
    final done=path.endsWith('/finalize');return jsonReply({'family_id':m.familyId,'backup_id':m.backupId,
      'scope':m.entries.any((e)=>e.kind=='sealed')?'opaque_restricted_unverified':'declared_public_files',
      'state':done?'incomplete':'uploading','complete':false,'full_device_complete':false,
      if(done)'verified_at':'2026-11-20T00:00:00Z','issues':<String>[],
      'entries':[for(final e in m.entries){'id':e.id,'kind':e.kind,'size':e.size,'offset':offsets[e.id]??0,if(e.missing.isNotEmpty)'missing':e.missing}]});
  }
}
Future<MobileBackupController> configured({required Directory parent,required ControllerCrypto crypto,required MemoryPreferences preferences,
    required ComputerDouble computer,required Future<BackupSnapshot> Function() snapshotProvider,String targetFamily='family'})async{
  final c=MobileBackupController(familyId:'family',deviceId:'device',crypto:crypto,preferences:preferences,snapshotProvider:snapshotProvider,
    privateDirectory:(_)async=>parent,transportFactory:(o,p)async=>computer.transport);
  await c.load();await c.pair(origin:computer.transport.origin,pin:computer.transport.pin,oneTimeCode:'3'*64,targetFamilyId:targetFamily);
  await c.createRecoveryKey();await c.revealRecoveryKey();await c.acknowledgeRecoveryKeySaved();return c;
}
void main(){
  test('construction and load never open native directory or contact a computer',()async{
    var directories=0,connections=0,snapshots=0;
    final c=MobileBackupController(familyId:'family',deviceId:'device',crypto:ControllerCrypto(),preferences:MemoryPreferences(),
      snapshotProvider:()async{snapshots++;throw StateError('unused');},privateDirectory:(_)async{directories++;throw StateError('unused');},
      transportFactory:(o,p)async{connections++;throw StateError('unused');});addTearDown(c.dispose);
    await c.load();expect([directories,connections,snapshots],[0,0,0]);expect(c.computer,isNull);expect(c.recordsApplied,false);
  });
  test('pair and key settings retain native refs; created key is not acknowledged as saved',()async{
    final prefs=MemoryPreferences(),crypto=ControllerCrypto(),computer=ComputerDouble();
    final c=MobileBackupController(familyId:'family',deviceId:'device',crypto:crypto,preferences:prefs,snapshotProvider:()async=>BackupSnapshot(sources:[]),
      privateDirectory:(_)async=>throw StateError('unused'),transportFactory:(o,p)async=>computer.transport);addTearDown(c.dispose);
    await c.load();await c.pair(origin:computer.transport.origin,pin:computer.transport.pin,oneTimeCode:'3'*64,targetFamilyId:'family');await c.createRecoveryKey();
    expect(c.recoveryKeySavedAcknowledged,false);expect(jsonEncode(prefs.data).contains('4'*64),false);
    await expectLater(c.acknowledgeRecoveryKeySaved(),throwsA(isA<BackupException>()));
    final key=await c.revealRecoveryKey();expect(key.length,64);expect(jsonEncode(prefs.data).contains(key),false);
    await c.acknowledgeRecoveryKeySaved();expect(c.recoveryKeySavedAcknowledged,true);
  });
  test('records are always sealed and lost ACK reuses identical frozen archive without preparing again',()async{
    final parent=await Directory.systemTemp.createTemp('wo-controller-synthetic-');addTearDown(()=>parent.delete(recursive:true));
    final crypto=ControllerCrypto(),prefs=MemoryPreferences(),computer=ComputerDouble();var prepared=0,released=0;
    final records=LocalSource('records',Uint8List.fromList(utf8.encode('{"private":"synthetic-only"}')));
    final photo=LocalSource('photo',Uint8List.fromList([1,2,3]),kind:'photo',exact:true);
    final c=await configured(parent:parent,crypto:crypto,preferences:prefs,computer:computer,snapshotProvider:()async{
      prepared++;return BackupSnapshot(sources:[records,photo],coverageNotes:['合成记录与原件'],omittedScopes:['未适配合成插件'],release:()async{released++;});
    });addTearDown(()async{if(c.hasPendingUpload)await c.discardPendingUpload();c.dispose();});
    computer.loseFirstAck=true;await expectLater(c.startBackup(allowPublicMediaOnComputer:true),throwsA(isA<BackupException>()));
    expect(c.hasPendingUpload,true);expect(prepared,1);expect(computer.manifest!.entries.any((e)=>e.kind=='records'),false);
    expect(computer.manifest!.entries.where((e)=>e.kind=='sealed').single.label,isEmpty);
    final canonical=computer.manifest!.canonicalJson,seals=crypto.seals;
    await expectLater(c.startBackup(),throwsA(isA<BackupException>()));
    await c.retryUpload();expect(prepared,1);expect(crypto.seals,seals);expect(computer.manifest!.canonicalJson,canonical);
    expect(released,1);expect(c.hasPendingUpload,false);expect(c.lastUpload!.fullDeviceComplete,false);expect(c.omittedScopes,['未适配合成插件']);
  },skip:Platform.isWindows);
  test('global pending reservation prevents another controller from preparing native snapshots',()async{
    final parent=await Directory.systemTemp.createTemp('wo-controller-global-');addTearDown(()=>parent.delete(recursive:true));
    final computer=ComputerDouble(),crypto=ControllerCrypto();var secondPrepared=0;
    final first=await configured(parent:parent,crypto:crypto,preferences:MemoryPreferences(),computer:computer,
      snapshotProvider:()async=>BackupSnapshot(sources:[LocalSource('records',Uint8List.fromList([1]))]));
    final second=MobileBackupController(familyId:'family',deviceId:'device2',crypto:ControllerCrypto(),preferences:MemoryPreferences(),
      snapshotProvider:()async{secondPrepared++;return BackupSnapshot(sources:[]);},privateDirectory:(_)async=>parent,transportFactory:(o,p)async=>computer.transport);
    addTearDown(()async{if(first.hasPendingUpload)await first.discardPendingUpload();first.dispose();second.dispose();});
    computer.loseFirstAck=true;await expectLater(first.startBackup(),throwsA(isA<BackupException>()));
    await expectLater(second.startBackup(),throwsA(isA<BackupException>().having((e)=>e.code,'code','frozen_backup_already_pending')));expect(secondPrepared,0);
    await first.discardPendingUpload();expect(first.hasPendingUpload,false);
  },skip:Platform.isWindows);
  test('restore-only family pairing cannot upload current family sources',()async{
    final parent=await Directory.systemTemp.createTemp('wo-controller-family-');addTearDown(()=>parent.delete(recursive:true));var prepared=0;
    final c=await configured(parent:parent,crypto:ControllerCrypto(),preferences:MemoryPreferences(),computer:ComputerDouble(),targetFamily:'old-family',
      snapshotProvider:()async{prepared++;return BackupSnapshot(sources:[]);});addTearDown(c.dispose);
    await expectLater(c.startBackup(),throwsA(isA<BackupException>().having((e)=>e.code,'code','paired_family_is_restore_only')));expect(prepared,0);
  });
}
