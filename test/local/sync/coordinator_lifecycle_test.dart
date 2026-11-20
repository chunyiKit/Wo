// 已准备但本轮未执行 Dart/Flutter/SDK；仅使用未来测试进程的临时SQLite与loopback。
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/sync/peer_registry.dart';
import 'package:wo/local/sync/sync_policy.dart';
import 'package:wo/local/sync/sync_coordinator.dart';
import 'package:wo/local/transport/native_local.dart';

class _NoSync implements IncrementalSyncStrategy {
  @override Future<Map<String,dynamic>> state(PeerLink peer) async=>throw StateError('没有配对时不应同步');
  @override Future<Map<String,dynamic>> delta(PeerLink peer,Map<String,dynamic> state) async=>throw StateError('没有配对时不应同步');
  @override Future<void> apply(PeerLink peer,Map<String,dynamic> delta) async=>throw StateError('没有配对时不应同步');
}
void main(){
  TestWidgetsFlutterBinding.ensureInitialized();sqfliteFfiInit();
  const control=MethodChannel('wo.test/discovery'),eventControl=MethodChannel('wo.test/discovery/events');
  const events=EventChannel('wo.test/discovery/events');
  final messenger=TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;late LocalStore store;late LocalSyncCoordinator coordinator;
  late Completer<void> started,release;late List<String> calls;
  setUp(()async{
    dir=await Directory.systemTemp.createTemp('wo-sync-lifecycle-');
    store=await LocalStore.open(factory:databaseFactoryFfi,path:'${dir.path}/local.sqlite');
    started=Completer<void>();release=Completer<void>();calls=[];
    messenger.setMockMethodCallHandler(control,(call)async{
      calls.add(call.method);if(call.method=='start'&&!started.isCompleted){started.complete();await release.future;}return null;
    });
    messenger.setMockMethodCallHandler(eventControl,(call)async=>null);
    final crypto=NativeCrypto(channel:const MethodChannel('wo.test/unused-crypto'));
    coordinator=LocalSyncCoordinator(store:store,registry:PeerRegistry(store,crypto),crypto:crypto,
      discovery:NativeDiscovery(channel:control,eventChannel:events),strategy:_NoSync());
  });
  tearDown(()async{
    if(!release.isCompleted)release.complete();await coordinator.stop();coordinator.dispose();
    messenger.setMockMethodCallHandler(control,null);messenger.setMockMethodCallHandler(eventControl,null);
    await store.close();await dir.delete(recursive:true);
  });
  test('dispose先使未完成start失效；迟到OS回调不notify或重建监听',()async{
    var changed=0;coordinator.addListener(()=>changed++);
    final starting=coordinator.start();await started.future;
    coordinator.dispose();final before=changed;release.complete();await starting;await coordinator.stop();
    expect(changed,before);expect(coordinator.port,isNull);
    final count=calls.where((c)=>c=='start').length;await coordinator.start();expect(calls.where((c)=>c=='start').length,count);
  });
  test('start stop start串行，新会话不会被旧清理关闭',()async{
    final first=coordinator.start();await started.future;
    final stopping=coordinator.stop(),second=coordinator.start();release.complete();
    await first;await stopping;await second;
    expect(calls.take(3),['start','stop','start']);expect(coordinator.port,isNotNull);
  });
  test('仅本地IP提示可连接，映射loopback/链路本地与IPv6作用域地址不变成公网',(){
    for(final address in ['127.0.0.1','10.1.2.3','172.16.0.1','192.168.2.3','169.254.1.2','::1','::ffff:127.0.0.1','fc00::1','fe80::1']){
      expect(LocalSyncCoordinator.localAddress(InternetAddress(address)),true,reason:address);
    }
    for(final address in ['8.8.8.8','172.32.0.1','169.255.1.2','2001:4860:4860::8888']){
      expect(LocalSyncCoordinator.localAddress(InternetAddress(address)),false,reason:address);
    }
  });
}
