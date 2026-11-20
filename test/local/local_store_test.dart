import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/local/local_store.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late LocalStore a,b;
  const space='family-test', collection='/families/family-test/records';
  setUp(() async {
    directory=await Directory.systemTemp.createTemp('wo-rebuild-store-');
    a=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/a.sqlite');
    b=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/b.sqlite');
  });
  tearDown(() async {await a.close();await b.close();await directory.delete(recursive:true);});

  test('身份、事实和日志重启保留；本地业务与非秘密索引原子提交',() async {
    final id=a.deviceId;
    await a.batch([{'space':space,'collection':collection,'id':'one','fields':{'body':'离线'}},
      {'space':space,'collection':collection,'id':'two','fields':{'body':'同笔'}}],privateUpdates:{'families':[space]});
    await a.close();a=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/a.sqlite');
    expect(a.deviceId,id);expect((await a.get(space,collection,'one'))!['body'],'离线');
    expect(await a.privateValue('families'),[space]);
    expect((await a.exportSince(space,{})),hasLength(2));
    expect(await a.vector(space),{id:2});
  });
  test('后一个本地变更无效时前一个事实、日志、索引和序号全部回滚',() async {
    await expectLater(a.batch([{'space':space,'collection':collection,'id':'one','fields':{'body':'不应提交'}},
      {'space':space,'collection':collection,'id':'two','fields':{'locator':'不能同步'}}],privateUpdates:{'families':[space]}),throwsFormatException);
    expect(await a.get(space,collection,'one'),isNull);expect(await a.exportSince(space,{}),isEmpty);
    expect(await a.privateValue('families'),isNull);expect(await a.vector(space),isEmpty);
    expect((await a.patch(space,collection,'one',{'body':'重试'}))['sequence'],1);
  });
  test('本地批次超过总字节限额全部回滚，空增量也验证空间',() async {
    final payload=List.filled(1000000,'x').join();
    await expectLater(a.batch([for(var i=0;i<9;i++){'space':space,'collection':collection,'id':'large-$i','fields':{'body':payload}}]),throwsFormatException);
    expect(await a.exportSince(space,{}),isEmpty);
    await expectLater(a.merge('../invalid',[]),throwsFormatException);
  });
  test('不同字段合并、同字段冲突确定性收敛；重复和字段键顺序不制造新记录',() async {
    final first=await a.patch(space,collection,'one',{'title':'初始','body':'原文'});
    await b.merge(space,[first]);
    await a.patch(space,collection,'one',{'title':'A'});
    await b.patch(space,collection,'one',{'body':'B','title':'B'});
    final fromA=await a.exportSince(space,{}),fromB=await b.exportSince(space,{});
    await a.merge(space,fromB);await b.merge(space,fromA.reversed.toList());
    expect(await a.get(space,collection,'one'),await b.get(space,collection,'one'));
    expect((await a.get(space,collection,'one'))!['body'],'B');
    final before=await a.revision(space,collection,'one');
    expect(await a.merge(space,fromB),0);expect(await a.revision(space,collection,'one'),before);
    final reordered={...first,'fields':{'body':'原文','title':'初始'}};
    expect(await b.merge(space,[reordered]),0);
  });
  test('乱序增量的向量只推进连续前缀，不吞掉丢失低序号',() async {
    final one=await a.patch(space,collection,'one',{'body':'1'});
    final two=await a.patch(space,collection,'two',{'body':'2'});
    await b.merge(space,[two]);expect((await b.vector(space))[a.deviceId],0);
    expect(await a.exportSince(space,await b.vector(space)),hasLength(2));
    await b.merge(space,[one]);expect((await b.vector(space))[a.deviceId],2);
  });
  test('删除墓碑不会被延迟离线编辑复活；两种合并顺序结果相同',() async {
    final start=await a.patch(space,collection,'one',{'body':'初始'});
    await b.merge(space,[start]);
    final edit=await b.patch(space,collection,'one',{'body':'迟到编辑'});
    final removed=await a.patch(space,collection,'one',{},delete:true);
    await a.merge(space,[edit]);await b.merge(space,[removed]);
    expect(await a.get(space,collection,'one'),isNull);expect(await b.get(space,collection,'one'),isNull);
    await a.patch(space,collection,'one',{'body':'再编辑也不恢复'});
    expect(await a.get(space,collection,'one'),isNull);
  });
  test('跨空间、同序号异内容和远端假冒本机的新操作整批拒绝',() async {
    final first=await a.patch(space,collection,'one',{'body':'真实'});
    await expectLater(b.merge('another',[first]),throwsFormatException);
    await b.merge(space,[first]);
    await expectLater(b.merge(space,[{...first,'fields':{'body':'篡改'}}]),throwsFormatException);
    await expectLater(b.merge(space,[{...first,'actor':b.deviceId,'sequence':9}]),throwsFormatException);
    expect((await b.get(space,collection,'one'))!['body'],'真实');
  });
  test('本机原照/原视频句柄与私有设置不进入公开空间增量，私密空间序号独立',() async {
    await a.saveDeviceReference('video','video','private-content-uri',{'sha256':'source-only'});
    await a.setPrivate('service-endpoint','https://test.invalid');
    await a.patch('private-room','/families/private-room/memories','private',{'body':'私密'});
    final public=await a.patch(space,collection,'public',{'body':'公开'});
    expect(public['sequence'],1);expect(public['clock'],1);
    final exported=LocalStore.canonical(await a.exportSince(space,{}));
    expect(exported,isNot(contains('private-content-uri')));expect(exported,isNot(contains('私密')));
    expect(exported,isNot(contains('test.invalid')));expect((await a.deviceReference('video'))!['kind'],'video');
  });
  test('补录旧日期和已有行附件/发送状态更新按本机应用 revision 可追到',() async {
    await a.patch(space,collection,'newer',{'event_date':'2026-11-20'});
    final cursor=await a.revision(space,collection,'newer');
    await a.patch(space,collection,'older',{'event_date':'2000-01-01'});
    await a.patch(space,collection,'newer',{'attachment':'ready','status':'sent'});
    final updated=await a.list(space,collection,afterRevision:cursor);
    expect(updated.map((v)=>v['id']),['older','newer']);
  });
}
