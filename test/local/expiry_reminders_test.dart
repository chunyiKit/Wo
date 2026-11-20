// 仅准备，未执行Flutter/Dart/SDK；不代表系统提醒或前台Timer实测。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/local/local_api.dart';
import 'package:wo/local/local_foreground_reminders.dart';
import 'package:wo/local/local_notification_preferences.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/recipe_expiry.dart';

void main(){
  sqfliteFfiInit();late Directory directory;late LocalStore store;late LocalApi api;
  late RecipeExpiryRoutes routes;late DateTime clock;late String fid;
  Future<void> install({bool enabled=true})async{await store.patch(fid,'/families/$fid/installed','expiry-card',{'plugin_id':'expiry','enabled':enabled});}
  Future<Json> create({Json fields=const{}})async{
    final result=await routes.request('POST',fid,['expiry','items'],body:{'name':'合成到期记录','expire_on':'2026-12-20',...fields});return Json.from(result!.data as Map);
  }
  Future<void> update(String id,Json fields)async{await routes.request('PUT',fid,['expiry','items',id],body:fields);}
  Future<List<Json>> notices()async=>store.list(fid,'/families/$fid/notifications');
  Future<void> reopen()async{await store.close();store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/db.sqlite');api=LocalApi(store,now:()=>clock);await api.initialize();routes=RecipeExpiryRoutes(store,now:()=>clock);}
  setUp(()async{directory=await Directory.systemTemp.createTemp('wo-expiry-reminders-');store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/db.sqlite');clock=DateTime(2026,11,20,23,59);api=LocalApi(store,now:()=>clock);await api.initialize();fid=api.familyId!;routes=RecipeExpiryRoutes(store,now:()=>clock);});
  tearDown(()async{await store.close();await directory.delete(recursive:true);});
  test('30天包含边界、当天预提醒和次日过期各一条且不续期',()async{
    await install();final item=await create();clock=DateTime(2026,11,19);expect(await routes.requestDueExpiryReminders(fid),0);
    clock=DateTime(2026,11,20);expect(await routes.requestDueExpiryReminders(fid),1);expect(await routes.requestDueExpiryReminders(fid),0);
    clock=DateTime(2026,12,20);expect(await routes.requestDueExpiryReminders(fid),0);clock=DateTime(2026,12,21);expect(await routes.requestDueExpiryReminders(fid),1);
    expect((await notices()).map((r)=>r['type']).toSet(),{'expiry_due','expiry_expired'});expect(await routes.requestDueExpiryReminders(fid),0);
    expect((await store.get(fid,'/families/$fid/plugins/expiry/items',item['id'] as String))!['expire_on'],'2026-12-20');
  });
  test('到期前开关只关闭预提醒，暂停active才关闭两个阶段',()async{
    await install();final muted=await create(fields:{'notify_enabled':false,'expire_on':'2026-11-20'}),paused=await create(fields:{'active':false,'expire_on':'2026-11-19'});
    expect(await routes.requestDueExpiryReminders(fid),0);clock=DateTime(2026,11,21);expect(await routes.requestDueExpiryReminders(fid),1);
    expect((await notices()).single['source_id'],muted['id']);expect((await notices()).single['type'],'expiry_expired');
    await update(paused['id'] as String,{'active':true});expect(await routes.requestDueExpiryReminders(fid),1);await update(paused['id'] as String,{'active':false});await update(paused['id'] as String,{'active':true});expect(await routes.requestDueExpiryReminders(fid),0);
  });
  test('未安装、禁用、删除卡片、删除记录均不继续生成',()async{
    final item=await create();expect(await routes.requestDueExpiryReminders(fid),0);await install(enabled:false);expect(await routes.requestDueExpiryReminders(fid),0);
    await store.patch(fid,'/families/$fid/installed','expiry-card',{},delete:true);expect(await routes.requestDueExpiryReminders(fid),0);
    await store.patch(fid,'/families/$fid/installed','expiry-new',{'plugin_id':'expiry','enabled':true});await routes.request('DELETE',fid,['expiry','items',item['id'] as String]);expect(await routes.requestDueExpiryReminders(fid),0);
  });
  test('收件人仅当前有效本机成员，其它成员不重复投影，本机失效或跨家庭禁止写',()async{
    await install();await create();
    for(final (id,fields) in <(String,Json)>[
      ('active-peer',{'user_id':'active-peer','family_id':fid,'status':'active'}),
      ('left-peer',{'user_id':'left-peer','family_id':fid,'status':'left'}),
      ('foreign-peer',{'user_id':'foreign-peer','family_id':'other-family','status':'active'}),
      ('spoof-peer',{'user_id':'someone-else','family_id':fid,'status':'active'}),
    ]){await store.patch(fid,'/families/$fid/members',id,fields);}
    expect(await routes.requestDueExpiryReminders(fid),1);expect((await notices()).single['recipient_ids'],<String>[store.deviceId]);
    final before=await store.vector(fid);await expectLater(routes.requestDueExpiryReminders('other-family'),throwsA(isA<ApiException>().having((e)=>e.statusCode,'status',403)));
    await store.patch(fid,'/families/$fid/members',store.deviceId,{'status':'left'});final revoked=await store.vector(fid);
    await expectLater(routes.requestDueExpiryReminders(fid),throwsA(isA<ApiException>().having((e)=>e.statusCode,'status',403)));expect(await store.vector(fid),revoked);expect(before,isNotEmpty);
  });
  test('同日期重复保存或改名称天数不重复，新日期重新生成',()async{
    await install();final item=await create(),id=item['id'] as String;expect(await routes.requestDueExpiryReminders(fid),1);
    await update(id,{'name':'新名称','notify_days_before':365,'expire_on':'2026-12-20'});expect(await routes.requestDueExpiryReminders(fid),0);
    await update(id,{'expire_on':'2027-01-20'});expect(await routes.requestDueExpiryReminders(fid),1);expect(await notices(),hasLength(2));
    await update(id,{'expire_on':'2026-12-20'});expect(await routes.requestDueExpiryReminders(fid),0);
  });
  test('读过隐藏和重启不重建，删除通知墓碑也不复用',()async{
    await install();await create();expect(await routes.requestDueExpiryReminders(fid),1);final id=(await notices()).single['id'] as String;
    await api.request('PATCH','/notifications/$id/read');await api.request('DELETE','/notifications/$id');await reopen();
    expect(await routes.requestDueExpiryReminders(fid),0);expect((await api.request('GET','/notifications')).data,isEmpty);
    await store.patch(fid,'/families/$fid/notifications',id,{},delete:true);expect(await routes.requestDueExpiryReminders(fid),0);expect(await notices(),isEmpty);
  });
  test('并发前台处理同一SQLite仅创建一条',()async{
    await install();await create();final other=RecipeExpiryRoutes(store,now:()=>clock);
    final counts=await Future.wait([routes.requestDueExpiryReminders(fid),other.requestDueExpiryReminders(fid)]);expect(counts.reduce((a,b)=>a+b),1);expect(await notices(),hasLength(1));
  });
  test('故障注入整批消息回滚，显式重试无漏项',()async{
    await install();await create();await create();final items=await store.list(fid,'/families/$fid/plugins/expiry/items');items.sort((a,b)=>(a['id'] as String).compareTo(b['id'] as String));
    await update(items.last['id'] as String,{'name':'second-fault'});final before=await store.vector(fid);
    await store.db.execute("CREATE TRIGGER reject_expiry BEFORE INSERT ON documents WHEN NEW.collection='/families/$fid/notifications' AND instr(NEW.data,'second-fault')>0 BEGIN SELECT RAISE(ABORT,'synthetic expiry notification failure'); END");
    await expectLater(routes.requestDueExpiryReminders(fid),throwsA(anything));expect(await notices(),isEmpty);expect(await store.vector(fid),before);
    await store.db.execute('DROP TRIGGER reject_expiry');expect(await routes.requestDueExpiryReminders(fid),2);expect(await routes.requestDueExpiryReminders(fid),0);
  });
  test('闰年0天窗口遵循本地日期，23:59到零点后才进入',()async{
    await install();await create(fields:{'expire_on':'2028-02-29','notify_days_before':0});clock=DateTime(2028,2,28,23,59,59);expect(await routes.requestDueExpiryReminders(fid),0);
    clock=DateTime(2028,2,29);expect(await routes.requestDueExpiryReminders(fid),1);clock=DateTime(2028,2,29,23,59);expect(await routes.requestDueExpiryReminders(fid),0);
    clock=DateTime(2028,3,1);expect(await routes.requestDueExpiryReminders(fid),1);expect((await notices()).map((r)=>r['source_occurrence']).toSet(),{'2028-02-29'});
  });
  test('超过256项分批续查，不因已发项阻塞后续',()async{
    await install();final base=await create();await routes.request('DELETE',fid,['expiry','items',base['id'] as String]);final fields=Json.from(base)..remove('id')..remove('days_until');
    for(var start=0;start<257;start+=256){await store.batch([for(var i=start;i<257&&i<start+256;i++){'space':fid,'collection':'/families/$fid/plugins/expiry/items','id':'item-$i','fields':{...fields,'family_id':fid,'name':'合成$i'}}]);}
    expect(await routes.requestDueExpiryReminders(fid),256);expect(await routes.requestDueExpiryReminders(fid),1);expect(await routes.requestDueExpiryReminders(fid),0);expect(await notices(),hasLength(257));
  });
  test('旧非法日期跳过但不阻断其它合法记录；helper前台接线生效',()async{
    await install();final bad=await create();await store.patch(fid,'/families/$fid/plugins/expiry/items',bad['id'] as String,{'expire_on':'2026-02-30'});await create();
    expect(await LocalForegroundReminders(store,now:()=>clock).run([fid],includeFinance:false),true);expect(await notices(),hasLength(1));expect(await LocalForegroundReminders(store,now:()=>clock).run([fid]),false);
    expect((await notices()).single['status'],'pending_local_delivery');
  });
  test('双SQLite离线各有稳定作者ID，合并后各viewer仅一条本机消息',()async{
    await install();await create();final peer=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/peer.sqlite');
    try{
      await store.patch(fid,'/families/$fid/members',peer.deviceId,{'user_id':peer.deviceId,'family_id':fid,'role':'member','status':'active'});
      await peer.merge(fid,await store.exportSince(fid,{}));final peerRoutes=RecipeExpiryRoutes(peer,now:()=>clock);
      expect(await routes.requestDueExpiryReminders(fid),1);expect(await peerRoutes.requestDueExpiryReminders(fid),1);
      final a=await notices(),b=await peer.list(fid,'/families/$fid/notifications');expect(a.single['id'],isNot(b.single['id']));expect(a.single['created_by'],store.deviceId);expect(b.single['created_by'],peer.deviceId);expect(a.single['recipient_ids'],[store.deviceId]);expect(b.single['recipient_ids'],[peer.deviceId]);expect(peer.deviceId,isNot(store.deviceId));
      final toPeer=await store.exportSince(fid,await peer.vector(fid)),toLocal=await peer.exportSince(fid,await store.vector(fid));await store.merge(fid,toLocal);await peer.merge(fid,toPeer);
      final merged=await notices();expect(merged,hasLength(2));expect(LocalStore.canonical(merged),LocalStore.canonical(await peer.list(fid,'/families/$fid/notifications')));
      expect((await api.request('GET','/notifications')).data,hasLength(1));expect(merged.where((row)=>(row['recipient_ids'] as List).contains(peer.deviceId)),hasLength(1));
      expect(await routes.requestDueExpiryReminders(fid),0);expect(await peerRoutes.requestDueExpiryReminders(fid),0);
    }finally{await peer.close();}
  });
  test('A预警同步B后B首次已过期仅生成B过期，不投影A预警',()async{
    await install();await create(fields:{'expire_on':'2026-11-21','notify_days_before':1});
    final peer=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/peer-clock.sqlite');final peerClock=DateTime(2026,11,22);
    try{
      await store.patch(fid,'/families/$fid/members',peer.deviceId,{'user_id':peer.deviceId,'family_id':fid,'role':'member','status':'active'});
      expect(await routes.requestDueExpiryReminders(fid),1);await peer.merge(fid,await store.exportSince(fid,{}));
      await peer.setPrivate('families',[fid]);final peerApi=LocalApi(peer,now:()=>peerClock);await peerApi.initialize();
      expect((await peerApi.request('GET','/notifications')).data,isEmpty);
      final peerRoutes=RecipeExpiryRoutes(peer,now:()=>peerClock);expect(await peerRoutes.requestDueExpiryReminders(fid),1);
      final visible=(await peerApi.request('GET','/notifications')).data as List;expect(visible,hasLength(1));expect((visible.single as Map)['type'],'expiry_expired');expect((visible.single as Map)['created_by'],peer.deviceId);
      expect(await peerRoutes.requestDueExpiryReminders(fid),0);expect((await peer.list(fid,'/families/$fid/notifications')).where((n)=>n['created_by']==peer.deviceId&&n['type']=='expiry_due'),isEmpty);
    }finally{await peer.close();}
  });
  test('A预警B过期的不同时钟下，改到未来允许两端各自新日期轮次',()async{
    await install();final row=await create(fields:{'expire_on':'2026-11-21','notify_days_before':1}),id=row['id'] as String;
    final peer=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/peer-future.sqlite');final peerClock=DateTime(2026,11,22);
    try{
      await store.patch(fid,'/families/$fid/members',peer.deviceId,{'user_id':peer.deviceId,'family_id':fid,'role':'member','status':'active'});
      expect(await routes.requestDueExpiryReminders(fid),1);await peer.merge(fid,await store.exportSince(fid,{}));
      final peerRoutes=RecipeExpiryRoutes(peer,now:()=>peerClock);expect(await peerRoutes.requestDueExpiryReminders(fid),1);
      await update(id,{'expire_on':'2026-12-20','notify_days_before':30});expect(await routes.requestDueExpiryReminders(fid),1);
      await peer.merge(fid,await store.exportSince(fid,await peer.vector(fid)));expect(await peerRoutes.requestDueExpiryReminders(fid),1);
      final own=(await peer.list(fid,'/families/$fid/notifications')).where((n)=>(n['recipient_ids'] as List).contains(peer.deviceId)).toList();
      expect(own,hasLength(2));expect(own.map((n)=>'${n['type']}:${n['source_occurrence']}').toSet(),{'expiry_expired:2026-11-21','expiry_due:2026-12-20'});
      expect(await peerRoutes.requestDueExpiryReminders(fid),0);expect(await routes.requestDueExpiryReminders(fid),0);
    }finally{await peer.close();}
  });
  test('本机总开关和expiry来源开关只阻止新增，坏配置关闭且历史保留',()async{
    await install();await create();expect(await routes.requestDueExpiryReminders(fid),1);await create();
    final before=await store.vector(fid);await store.setPrivate(LocalNotificationPreferences.privateKey,{'push_enabled':false,'sources':{'expiry':true}});
    expect(await routes.requestDueExpiryReminders(fid),0);expect(await notices(),hasLength(1));expect(await store.vector(fid),before);
    await store.setPrivate(LocalNotificationPreferences.privateKey,{'push_enabled':true,'sources':{'expiry':false}});expect(await routes.requestDueExpiryReminders(fid),0);
    await store.setPrivate(LocalNotificationPreferences.privateKey,{'push_enabled':'true','sources':{'expiry':true}});expect(await routes.requestDueExpiryReminders(fid),0);
    await store.db.update('meta',{'value':'not-json'},where:'key=?',whereArgs:['private:${LocalNotificationPreferences.privateKey}']);expect(await routes.requestDueExpiryReminders(fid),0);
    await store.setPrivate(LocalNotificationPreferences.privateKey,null);expect(await routes.requestDueExpiryReminders(fid),1);expect(await notices(),hasLength(2));
  });
  test('A关闭本机偏好不影响B，私有偏好不进入同步或删除历史',()async{
    await install();await create();final peer=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/peer-prefs.sqlite');
    try{
      await store.patch(fid,'/families/$fid/members',peer.deviceId,{'user_id':peer.deviceId,'family_id':fid,'role':'member','status':'active'});
      await peer.merge(fid,await store.exportSince(fid,{}));await store.setPrivate(LocalNotificationPreferences.privateKey,{'push_enabled':false,'sources':{'expiry':true}});
      expect(await routes.requestDueExpiryReminders(fid),0);final peerRoutes=RecipeExpiryRoutes(peer,now:()=>clock);expect(await peerRoutes.requestDueExpiryReminders(fid),1);
      expect(await peer.privateValue(LocalNotificationPreferences.privateKey),isNull);expect(LocalStore.canonical(await store.exportSince(fid,{})),isNot(contains('notification-preferences')));
      await store.setPrivate(LocalNotificationPreferences.privateKey,{'push_enabled':true,'sources':{'expiry':true}});expect(await routes.requestDueExpiryReminders(fid),1);
      await peer.setPrivate(LocalNotificationPreferences.privateKey,{'push_enabled':false,'sources':{'expiry':false}});expect(await peerRoutes.requestDueExpiryReminders(fid),0);expect(await peer.list(fid,'/families/$fid/notifications'),hasLength(1));
    }finally{await peer.close();}
  });

}
