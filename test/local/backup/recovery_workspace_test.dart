// 准备的Dart/SQLite测试；当前执行限制下未运行，不代表原生实测。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/local/backup/backup_models.dart';
import 'package:wo/local/backup/portable_archive.dart';
import 'package:wo/local/backup/recovery_workspace.dart';
import 'package:wo/local/sync/sync_policy.dart';
import 'package:wo/local/transport/native_local.dart';
import 'mobile_backup_client_test.dart' show TestCrypto;

class _Bytes implements BackupSource {
  _Bytes(this.id,this.kind,this.bytes,{this.exact=false});final String id,kind;final Uint8List bytes;final bool exact;
  @override BackupEntry get entry=>BackupEntry(id:id,kind:kind,size:bytes.length,sha256:hashing.sha256.convert(bytes).toString(),sourceExact:exact);
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async=>Stream.value(bytes.sublist(offset,offset+length));
}
void main(){
  TestWidgetsFlutterBinding.ensureInitialized();sqfliteFfiInit();
  const channel=MethodChannel('wo.local/crypto');
  late Directory root;late RecoveryWorkspaceStore store;var nonce=0;late Set<String> nativeCalls;
  Future<RecoveryWorkspaceStore> open()=>RecoveryWorkspaceStore.openNative(crypto:NativeCrypto(channel:channel),schemas:LocalIncrementalStrategy.baseSchemas,commentFields:LocalIncrementalStrategy.commentFields,validateFields:LocalIncrementalStrategy.validatePortableFields,factory:databaseFactoryFfi);
  Future<PortableRestore> archive({String family='family',bool missing=false,bool duplicate=false})async{
    final document={'space':family,'collection':'/families/$family/family','id':family,'fields':{'name':'合成家庭','emoji':'🏡','created_at':'2026-11-20T00:00:00Z'}};
    final sources=[_Bytes('records','records',Uint8List.fromList(utf8.encode(jsonEncode({'version':1,'family_id':family,'records_applied':false,'documents':[document,if(duplicate)document]})))),
      if(!missing)_Bytes('original','photo',Uint8List.fromList(List.generate(128,(i)=>i)),exact:true)];
    final manifest=PortableManifest(familyId:family,entries:[for(final s in sources)PortableEntry(id:s.id,kind:s.kind,size:s.entry.size,sha256:s.entry.sha256,sourceExact:s.exact),
      if(missing)PortableEntry(id:'original',kind:'photo',size:0,sha256:'',sourceExact:false,missingReason:'source_missing')]);
    final directory=await Directory('${root.path}/quarantine').create(recursive:true);
    return PortableArchive(TestCrypto()).restoreToNewDirectory(PortableArchive(TestCrypto()).pack(manifest,{for(final s in sources)s.id:s}),directory,expectedFamily:family);
  }
  setUp(()async{
    root=await Directory.systemTemp.createTemp('wo-recovery-test-');nativeCalls={};nonce=0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call)async{
      nativeCalls.add(call.method);
      if(call.method=='privateDirectory'){final name=(call.arguments as Map)['name'] as String;return (await Directory('${root.path}/$name').create()).path;}
      if(call.method=='random'){nonce++;return Uint8List.fromList(List.generate((call.arguments as Map)['count'] as int,(i)=>(nonce+i)%256));}
      throw PlatformException(code:'old_identity_or_media_access_forbidden');
    });store=await open();
  });
  tearDown(()async{await store.close();TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,null);await root.delete(recursive:true);});
  test('没有确认不导入；确认摘要绑定实际清单',()async{
    final restore=await archive(),plan=await store.preview(await archive());
    await expectLater(store.importVerified(restore,confirmed:false,expectedFingerprint:plan.fingerprint),throwsA(isA<BackupException>()));
    await expectLater(store.importVerified(restore,confirmed:true,expectedFingerprint:'wrong'),throwsA(isA<BackupException>()));
    expect(await store.list(),isEmpty);
  },skip:Platform.isWindows);
  test('新身份独立持久库在重启后读原字节并再备份；无旧权限调用',()async{
    final restore=await archive(),plan=await store.preview(await archive());
    final workspace=await store.importVerified(restore,confirmed:true,expectedFingerprint:plan.fingerprint);
    expect(workspace.ownerDeviceId,isNot(restore.newDeviceId));expect(workspace.ownerDeviceId,isNot('old-device'));
    expect(workspace.normalImportAllowed,false);expect(workspace.peerExportable,false);expect(workspace.fullDeviceComplete,false);
    final first=await store.assets(workspace.id);final original=first.singleWhere((e)=>e.kind=='photo');
    expect(original.id,isNot('original'));expect(original.restricted,true);
    await store.close();store=await open();
    final file=await store.media.verifiedFile(workspace.id,original.id);expect(file,isNotNull);
    final bytes=await file!.readAsBytes();expect(hashing.sha256.convert(bytes).toString(),restore.files['original']!.entry.sha256);
    final snapshot=await store.snapshot(workspace.id),source=(await store.snapshot(workspace.id)).sources.singleWhere((s)=>s.entry.kind=='photo');
    final output=<int>[];await for(final part in await source.openRange(0,source.entry.size)){output.addAll(part);}
    expect(output,bytes);expect(source.privacy,BackupPrivacy.restricted);expect(source.entry.sourceExact,true);
    expect(snapshot.omittedScopes,isNotEmpty);expect(nativeCalls.difference({'privateDirectory','random'}),isEmpty);
  },skip:Platform.isWindows);
  test('同清单重试幂等；不同归档创建新私有资料库',()async{
    final a=await archive(),p=await store.preview(a),one=await store.importVerified(a,confirmed:true,expectedFingerprint:p.fingerprint);
    final retry=await store.importVerified(await archive(),confirmed:true,expectedFingerprint:p.fingerprint);expect(retry.id,one.id);
    final b=await archive(family:'another'),q=await store.preview(b),two=await store.importVerified(b,confirmed:true,expectedFingerprint:q.fingerprint);
    expect(two.id,isNot(one.id));expect((await store.list()).length,2);expect((await store.documents(one.id)).single.fields['name'],'合成家庭');
  },skip:Platform.isWindows);
  test('缺原件保留缺件；不声称业务或整机恢复',()async{
    final r=await archive(missing:true),p=await store.preview(r),w=await store.importVerified(r,confirmed:true,expectedFingerprint:p.fingerprint);
    expect(w.missingCount,1);expect(w.recordsApplied,false);expect(w.fullDeviceComplete,false);
    final asset=(await store.assets(w.id)).singleWhere((e)=>e.kind=='photo');expect(asset.available,false);
    expect(await store.media.verifiedFile(w.id,asset.id),isNull);
  },skip:Platform.isWindows);
  test('预览后原件篡改不能发布；重试不覆盖已拥有字节',()async{
    final r=await archive(),p=await store.preview(r);await r.files['original']!.file.writeAsBytes([9],flush:true);
    await expectLater(store.importVerified(r,confirmed:true,expectedFingerprint:p.fingerprint),throwsA(anything));expect(await store.list(),isEmpty);
    final fixed=await archive(),w=await store.importVerified(fixed,confirmed:true,expectedFingerprint:p.fingerprint);
    expect((await store.list()).single.id,w.id);expect((await store.assets(w.id)).singleWhere((e)=>e.kind=='photo').available,true);
  },skip:Platform.isWindows);
  test('重复历史键不发布；未知版本不会当作业务状态执行',()async{
    final r=await archive(duplicate:true);await expectLater(store.preview(r),throwsA(isA<BackupException>()));expect(await store.list(),isEmpty);
  },skip:Platform.isWindows);
  test('已发布原件损坏时幂等重取失败，不覆盖或假装修复旧资料库',()async{
    final r=await archive(),p=await store.preview(r),w=await store.importVerified(r,confirmed:true,expectedFingerprint:p.fingerprint);
    final a=(await store.assets(w.id)).singleWhere((e)=>e.kind=='photo'),file=await store.media.verifiedFile(w.id,(await store.assets(w.id)).singleWhere((e)=>e.kind=='photo').id);
    await file!.writeAsBytes([8],flush:true);
    await expectLater(store.importVerified(await archive(),confirmed:true,expectedFingerprint:p.fingerprint),throwsA(anything));
    expect(await file.readAsBytes(),[8]);expect((await store.list()).single.id,w.id);expect(a.restricted,true);
  },skip:Platform.isWindows);

}
