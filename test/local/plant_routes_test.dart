import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/local/local_backend.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/plant_routes.dart';
import 'package:wo/services/external_services.dart';

void main(){
  sqfliteFfiInit();const fid='plant-family';late Directory directory;late LocalStore store;late PlantRoutes routes;late DateTime clock;
  Matcher error(int status)=>throwsA(isA<ApiException>().having((e)=>e.statusCode,'status',status));
  Future<LocalResult> call(String method,List<String> tail,{Json body=const{},String family=fid})async{final result=await routes.request(method,family,['plant',...tail],body:body);expect(result,isNotNull);return result!;}
  Future<Json> create({Json body=const{}})async=>Json.from((await call('POST',['plants'],body:{'name':'植物',...body})).data as Map);
  setUp(()async{directory=await Directory.systemTemp.createTemp('wo-plant-');store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/local.sqlite');await store.patch(fid,'/families/$fid/members',store.deviceId,{'user_id':store.deviceId,'family_id':fid,'role':'owner','status':'active','display_name':'本机成员','avatar_emoji':'🐱','avatar_url':null});clock=DateTime.utc(2026,1,1,12);routes=PlantRoutes(store,now:()=>clock);});
  tearDown(()async{await store.close();await directory.delete(recursive:true);});
  test('植物模型CRUD/周期/重启，修改一个周期不重置另一周期',()async{
    final created=Plant.fromJson(await create(body:{'name':' 绿萝 ','water_interval_days':2,'fert_interval_days':10,'species':'绿萝'}));expect(created.name,'绿萝');expect(created.nextWaterDue,DateTime(2026,1,3));expect(created.nextFertDue,DateTime(2026,1,11));
    clock=DateTime.utc(2026,1,5);
    await call('PUT',['plants',created.id],body:{'water_interval_days':3,'species':null});
    final updated=Plant.fromJson(Json.from((await call('GET',['plants',created.id])).data as Map));expect(updated.nextWaterDue,DateTime(2026,1,8));expect(updated.nextFertDue,DateTime(2026,1,11));expect(updated.species,isNull);
    await call('PATCH',['plants',created.id],body:{'water_interval_days':null});
    await store.close();store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/local.sqlite');routes=PlantRoutes(store,now:()=>clock);
    final read=Plant.fromJson(Json.from((await call('GET',['plants',created.id])).data as Map));expect(read.waterIntervalDays,isNull);expect(read.nextWaterDue,isNull);expect(read.fertIntervalDays,10);
    expect((await call('DELETE',['plants',created.id])).data,isNull);expect((await call('DELETE',['plants',created.id])).data,isNull);await expectLater(call('GET',['plants',created.id]),error(404));
  });
  test('文字养护日志独立本地保存，不伪造照片或AI进行中',()async{
    final plant=await create();final id=plant['id'] as String;
    final log=PlantLog.fromJson(Json.from((await call('POST',['plants',id,'logs'],body:{'note':' 手工浇水记录 '})).data as Map));
    expect(log.note,'手工浇水记录');expect(log.aiPending,isFalse);expect(log.aiAssessment,isNull);expect(log.photoUrls,isEmpty);expect(log.envSnapshot,{'placement':'室内'});
    expect((await call('GET',['plants',id,'logs'])).data,hasLength(1));
    await expectLater(call('POST',['plants',id,'logs'],body:{'note':'不能假保存照片','media_ids':['one']}),error(501));
    await expectLater(call('POST',['plants',id,'logs',log.id,'reanalyze']),error(501));
    await expectLater(call('GET',['plants',id,'cover']),error(501));
    await call('DELETE',['plants',id]);expect(await store.list(fid,'/families/$fid/plugins/plant/logs'),isEmpty);
    await expectLater(call('GET',['plants',id,'logs',log.id]),error(404));
  });
  test('只显式采纳已有本地建议，未授权远程分析不触发',()async{
    final plant=await create(),id=plant['id'] as String;
    final log=PlantLog.fromJson(Json.from((await call('POST',['plants',id,'logs'],body:{'note':'保留记录'})).data as Map));
    await expectLater(call('POST',['plants',id,'logs',log.id,'adopt'],body:{'water':true}),error(400));
    // 模拟已验证历史归档中保留的建议，不调用模型或为新日志伪造AI结果。
    await store.patch(fid,'/families/$fid/plugins/plant/logs',log.id,{'ai_suggested_water_days':5,'ai_suggested_fert_days':20});
    final adopted=Plant.fromJson(Json.from((await call('POST',['plants',id,'logs',log.id,'adopt'],body:{'water':true,'fert':false})).data as Map));expect(adopted.waterIntervalDays,5);expect(adopted.fertIntervalDays,isNull);expect(adopted.nextWaterDue,DateTime(2026,1,6));
    await expectLater(call('POST',['plants',id,'logs',log.id,'adopt'],body:{'water':'true'}),error(400));
  });
  test('手编默认位置私有，摆放标签共享且遵循原有默认回退',()async{
    final first=PlantFamilySettings.fromJson(Json.from((await call('GET',['settings'])).data as Map));expect(first.placements,hasLength(5));
    await call('PUT',['settings'],body:{'latitude':34.0,'longitude':108.0,'location_label':'手编默认','placements':[' 室内 ','室内','南阳台']});
    final saved=PlantFamilySettings.fromJson(await routes.settings(fid));expect(saved.latitude,34);expect(saved.placements,['室内','南阳台']);
    final wire=LocalStore.canonical(await store.exportSince(fid,{}));expect(wire,isNot(contains('latitude')));expect(wire,isNot(contains('longitude')));expect(wire,isNot(contains('手编默认')));
    await call('PUT',['settings'],body:{'placements':<String>[]});expect((await routes.settings(fid))['placements'],hasLength(5));
    await expectLater(call('PUT',['settings'],body:{'latitude':91,'placements':['不应提交']}),error(400));expect((await routes.settings(fid))['placements'],hasLength(5));
  });
  test('两次前台天气位置和拒绝授权均不改变默认/记录/journal，UV零保留',()async{
    await call('PUT',['settings'],body:{'latitude':34.0,'longitude':108.0,'location_label':'手编默认'});
    final privateBefore=await store.privateValue('plant-manual-environment:$fid'),vectorBefore=await store.vector(fid);var calls=0,providerRequests=0,denied=false;
    routes=PlantRoutes(store,now:()=>clock,currentWeather:()async{
      calls++;if(denied)throw const ExternalServiceException('天气',ServiceFailure.locationDenied);
      providerRequests++;return {'available':true,'latitude':calls==1?31.23:22.33,'longitude':calls==1?121.46:114.0,'humidity_pct':69,'cloud_pct':5,'visibility_km':29.02,'wind_speed_kmh':17.064,'uv_index':0,'api_key':'synthetic-test-must-not-escape'};
    });
    final automatic=(await call('GET',['weather'])).data as Map;expect(automatic['reason'],'explicit_action_required');expect(calls,0);expect(providerRequests,0);
    final a=await routes.weatherForUserAction(fid),b=await routes.weatherForUserAction(fid);expect(a['latitude'],31.23);expect(b['latitude'],22.33);expect(a['uv_index'],0);expect(a.containsKey('api_key'),isFalse);
    denied=true;final refused=PlantWeather.fromJson(await routes.weatherForUserAction(fid));expect(refused.available,isFalse);expect(calls,3);expect(providerRequests,2);
    expect(await store.privateValue('plant-manual-environment:$fid'),privateBefore);expect(await store.vector(fid),vectorBefore);expect(await store.list(fid,'/families/$fid/plugins/plant/logs'),isEmpty);
    await store.patch(fid,'/families/$fid/members',store.deviceId,{'status':'left'});await expectLater(call('GET',['weather']),error(403));await expectLater(routes.weatherForUserAction(fid),error(403));expect(calls,3);
  });
  test('养护到期请求和周期推进同批提交，错过多日一次推进到未来',()async{
    final plant=await create(body:{'water_interval_days':2,'fert_interval_days':4}),id=plant['id'] as String;clock=DateTime.utc(2026,1,10);
    expect(await routes.requestDueReminders(fid),1);expect(await routes.requestDueReminders(fid),0);
    final row=Plant.fromJson(Json.from((await call('GET',['plants',id])).data as Map));expect(row.nextWaterDue,DateTime(2026,1,11));expect(row.nextFertDue,DateTime(2026,1,13));
    final pending=await store.list(fid,'/families/$fid/notifications');expect(pending,hasLength(2));expect(pending.map((n)=>n['type']),containsAll(['plant_water_due','plant_fert_due']));expect(pending.every((n)=>n['status']=='pending_local_delivery'),isTrue);
    expect((await routes.preview(fid))['primary'],contains('浇水'));
  });
  test('到期请求SQLite写失败不会先推进周期，后续可安全重试',()async{
    final plant=await create(body:{'water_interval_days':1}),id=plant['id'] as String;clock=DateTime.utc(2026,1,3);
    await store.db.execute("CREATE TRIGGER reject_plant_notification BEFORE INSERT ON documents WHEN NEW.collection = '/families/$fid/notifications' BEGIN SELECT RAISE(ABORT, 'plant synthetic notification failure'); END");
    final before=await store.vector(fid);await expectLater(routes.requestDueReminders(fid),throwsA(predicate((e)=>'$e'.contains('plant synthetic notification failure'))));
    expect((await store.get(fid,'/families/$fid/plugins/plant/plants',id))!['next_water_due'],'2026-01-02');expect(await store.vector(fid),before);
    await store.db.execute('DROP TRIGGER reject_plant_notification');expect(await routes.requestDueReminders(fid),1);
  });
  test('错误字段/周期/身份/路径不假成功，缺天气仍能本地CRUD',()async{
    for(final body in <Json>[{'name':' '},{'name':'字'*41},{'water_interval_days':0},{'fert_interval_days':366},{'created_by':'forged'}]){await expectLater(create(body:body),error(400));}
    expect((await call('GET',['plants'])).data,isEmpty);expect(PlantWeather.fromJson(Json.from((await call('GET',['weather'])).data as Map)).available,isFalse);
    final plant=await create();await expectLater(call('GET',['plants',plant['id'] as String],family:'unjoined-family'),error(403));
    await expectLater(call('DELETE',['plants','unknown']),error(404));await expectLater(call('POST',['weather']),error(405));expect(await routes.request('GET',fid,['plant','unknown']),isNull);
  });
}
