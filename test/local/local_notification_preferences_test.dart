// 已准备；未执行Dart/Flutter/SDK。只测试本机站内设置，不证明系统推送。
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/local/local_api.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/local_notification_preferences.dart';

void main(){
  sqfliteFfiInit();late Directory directory;late LocalStore store;late LocalApi api;
  Future<Json> get()async=>Json.from((await api.request('GET','/me/notification-preferences')).data as Map);
  Future<Json> patch(Json body)async=>Json.from((await api.request('PATCH','/me/notification-preferences',body:body)).data as Map);
  setUp(()async{directory=await Directory.systemTemp.createTemp('wo-local-notification-prefs-');store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/local.sqlite');api=LocalApi(store);await api.initialize();});
  tearDown(()async{await store.close();await directory.delete(recursive:true);});
  test('真实默认保留本机expiry站内能力、响应明确不支持OS推送',()async{
    final value=await get(),model=NotificationPreferences.fromJson(await get());
    expect(model.pushEnabled,true);expect(model.sources.single.key,'expiry');expect(model.sources.single.enabled,true);
    expect(value['delivery'],'local_message_center');expect(value['system_push_supported'],false);
    expect(await store.privateValue(LocalNotificationPreferences.privateKey),isNull);
  });
  test('本机总开关与expiry来源独立保存，关闭总开关不抹来源状态，重开保持',()async{
    await HttpOverrides.runZoned(()async{
      await patch({'sources':{'expiry':false}});await patch({'push_enabled':false});await patch({'push_enabled':true});
      expect(NotificationPreferences.fromJson(await get()).sources.single.enabled,false);
      await store.close();store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/local.sqlite');api=LocalApi(store);await api.initialize();
      final value=LocalNotificationPreferences.fromPrivateValue(await store.privateValue(LocalNotificationPreferences.privateKey));
      expect(value.enabled,true);expect(value.expirySourceEnabled,false);expect(value.expiryEnabled,false);
    },createHttpClient:(_)=>throw StateError('本机偏好不应联网'));
  });
  test('并行修改不同开关使用事务读取当前值，不发生覆盖',()async{
    await Future.wait([patch({'push_enabled':false}),patch({'sources':{'expiry':false}})]);
    expect(await store.privateValue(LocalNotificationPreferences.privateKey),{'push_enabled':false,'sources':{'expiry':false}});
  });
  test('不接受其它来源、系统投递设置或错误类型，失败不改已有值',()async{
    await patch({'sources':{'expiry':false}});final before=await store.privateValue(LocalNotificationPreferences.privateKey);
    for(final body in <Json>[{}, {'push_enabled':null},{'push_enabled':'yes'},{'system_push_supported':true},{'sources':null},{'sources':[]},{'sources':{'pet':true}},{'sources':{'expiry':null}}]){
      await expectLater(patch(body),throwsA(isA<ApiException>()));expect(await store.privateValue(LocalNotificationPreferences.privateKey),before);
    }
  });
  test('A私有偏好不进入peer操作，不影响B开关',()async{
    final fid=api.familyId!,before=await store.vector(api.familyId!);
    final other=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/other.sqlite');
    try{
      final otherApi=LocalApi(other);await otherApi.initialize();await patch({'push_enabled':false,'sources':{'expiry':false}});
      await other.merge(fid,await store.exportSince(fid,{}));expect(await store.vector(fid),before);
      final b=Json.from((await otherApi.request('GET','/me/notification-preferences')).data as Map);
      expect(b['push_enabled'],true);expect((b['sources'] as List).single['enabled'],true);
      expect(await other.privateValue(LocalNotificationPreferences.privateKey),isNull);
    }finally{await other.close();}
  });
  test('停用只影响后续生成，既有历史、已读时间与隐藏标记保留',()async{
    final fid=api.familyId!;await store.patch(fid,'/families/$fid/notifications','history',{'type':'expiry_due','title':'旧站内消息','body':'保留','created_at':'2026-11-20T00:00:00Z','recipient_ids':[store.deviceId]});
    await api.request('PATCH','/notifications/history/read');final marker=await store.privateValue('notification-read:$fid:history');
    await patch({'push_enabled':false});final rows=(await api.request('GET','/notifications')).data as List;
    expect(rows.single['title'],'旧站内消息');expect(rows.single['is_read'],true);expect(await store.privateValue('notification-read:$fid:history'),marker);
    await api.request('DELETE','/notifications/history');await patch({'push_enabled':true});expect((await api.request('GET','/notifications')).data,isEmpty);
  });
  test('旧列表形状保留真实总开关，损坏配置failclosed且不删历史',()async{
    await store.setPrivate(LocalNotificationPreferences.privateKey,{'push_enabled':false,'sources':[]});expect((await get())['push_enabled'],false);
    for(final value in [false,{'push_enabled':null},{'sources':{'expiry':null}},{'sources':'wrong'}]){
      expect(LocalNotificationPreferences.fromPrivateValue(value).expiryEnabled,false);
    }
    await store.db.rawInsert('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',['private:notification-preferences','not-json']);
    expect((await get())['push_enabled'],false);
    expect(await store.privateValue('unrelated-history-flag'),isNull);
    await patch({'push_enabled':true,'sources':{'expiry':true}});
    expect(jsonDecode((await store.db.query('meta',where:'key=?',whereArgs:['private:notification-preferences'])).single['value'] as String),{'push_enabled':true,'sources':{'expiry':true}});
  });
}
