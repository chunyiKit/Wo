// 已准备；当前执行限制下未运行Dart/Flutter，不能作为原生验收证据。
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/local_media_repository.dart';
import 'package:wo/local/media/native_media.dart';
import 'package:wo/local/plugins/memory_routes.dart';
import 'package:wo/local/sync/peer_registry.dart';
import 'package:wo/local/sync/sync_policy.dart';
import 'package:wo/local/transport/native_local.dart';
import 'package:wo/local/backup/backup_models.dart';
import 'package:wo/local/backup/local_backup_snapshot.dart';

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();sqfliteFfiInit();
  const channel=MethodChannel('wo.local/crypto'),fid='family-backup';
  late Directory root;late LocalStore store;late LocalBackupSnapshots snapshots;
  late MemoryRoutes memories;
  setUp(()async{
    root=await Directory.systemTemp.createTemp('wo-snapshot-test-');
    store=await LocalStore.open(path:'${root.path}/test.sqlite',factory:databaseFactoryFfi);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call)async{
      if(call.method=='privateDirectory')return root.path;throw PlatformException(code:'unexpected_native_call');
    });
    await store.patch(fid,'/families/$fid/family',fid,{'name':'合成家庭','emoji':'🏡','created_at':'2026-11-20T00:00:00Z'});
    await store.patch(fid,'/families/$fid/members',store.deviceId,{'family_id':fid,'user_id':store.deviceId,'role':'owner','status':'active','display_name':'合成成员','avatar_emoji':'👤','joined_at':'2026-11-20T00:00:00Z'});
    final media=LocalMediaRepository(store,native:NativeMedia(),directory:Directory('${root.path}/thumbs'));
    memories=MemoryRoutes(store,media:media,access:LocalMemoryAccess(store));
    snapshots=LocalBackupSnapshots(store:store,media:media,memories:memories,crypto:NativeCrypto(channel:channel),schemas:LocalIncrementalStrategy.baseSchemas);
  });
  tearDown(()async{TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,null);await store.close();await root.delete(recursive:true);});
  test('已授权私密正文只在受限惰性records中；配置和句柄均不导出',()async{
    await memories.request('POST',fid,['memory','memories'],body:{'title':'合成私密标题','body':'合成正文','event_date':'2026-11-20','visibility':'private'});
    await store.setPrivate('api_key','synthetic-secret-not-exported');
    await store.saveDeviceReference('unbound-original','photo','synthetic-native-handle',{'scope':null});
    final snapshot=await snapshots.create(fid);
    try{
      expect(snapshot.sources.length,1);final records=snapshot.sources.single;
      expect(records.entry.kind,'records');expect(records.privacy,BackupPrivacy.restricted);
      final bytes=<int>[];await for(final chunk in await records.openRange(0,records.entry.size)){bytes.addAll(chunk);}
      final raw=utf8.decode(bytes),data=jsonDecode(raw) as Map;
      expect(data['records_applied'],false);expect(raw,contains('合成私密标题'));
      for(final forbidden in ['synthetic-secret-not-exported','synthetic-native-handle','device_refs','secret_ref','locator']){expect(raw,isNot(contains(forbidden)));}
    }finally{await snapshot.release?.call();}
  });
  test('无本地有效成员时备份失败，不创建原件或请求网络',()async{
    await store.patch(fid,'/families/$fid/members',store.deviceId,{'status':'revoked'});
    await expectLater(snapshots.create(fid),throwsA(isA<BackupException>().having((e)=>e.code,'code','family_authorization_required')));
    expect(await root.list().where((entity)=>entity is Directory).isEmpty,true);
  });
  test('未知集合明确记录遗漏，不把未验证文档伪装为完整',()async{
    await store.patch(fid,'/families/$fid/plugins/future/items','one',{'family_id':fid,'title':'合成未知记录'});
    final snapshot=await snapshots.create(fid);
    try{expect(snapshot.omittedScopes,contains('plugins/future/items'));expect(snapshot.coverageNotes.any((text)=>text.contains('尚未安全导入')),true);}
    finally{await snapshot.release?.call();}
  });
}
