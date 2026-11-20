import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/local/local_backend.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/pet_routes.dart';
import 'package:wo/local/attachments/attachment_descriptor.dart';

void main(){
  sqfliteFfiInit();const fid='pet-family';late Directory dir;late LocalStore store;late PetRoutes routes;late DateTime clock;
  Matcher error(int status)=>throwsA(isA<ApiException>().having((e)=>e.statusCode,'status',status));
  Future<LocalResult> call(String method,List<String> tail,{Json body=const{},Json query=const{},String family=fid})async{final result=await routes.request(method,family,tail,body:body,query:query);expect(result,isNotNull);return result!;}
  Future<Json> object(String method,List<String> tail,{Json body=const{}})async=>Json.from((await call(method,tail,body:body)).data as Map);
  Future<Json> pet()async=>object('POST',['pets'],body:{'name':'小猫','birthday':'2024-02-29','birthday_estimated':true});
  Future<List<Json>> types()async=>[for(final item in (await call('GET',['pet','record-types'])).data as List)Json.from(item as Map)];
  Future<Json> plan(String petId,String typeId,{Json extra=const{}})async=>object('POST',['pet','pets',petId,'plans'],body:{'record_type_id':typeId,'name':'照护','recurrence_unit':'month','recurrence_interval':1,'next_due_date':'2026-01-31',...extra});
  Future<Json> record(String petId,String typeId,{Json extra=const{}})async=>object('POST',['pet','pets',petId,'records'],body:{'record_type_id':typeId,'name':'记录','occurred_on':'2026-01-01',...extra});
  Future<void> member(String id,{String role='member'})async{await store.patch(fid,'/families/$fid/members',id,{'user_id':id,'family_id':fid,'role':role,'status':'active','display_name':'成员$id','avatar_emoji':'🐱','avatar_url':'wo-local-avatar://$id/1'});}
  setUp(()async{dir=await Directory.systemTemp.createTemp('wo-pet-');store=await LocalStore.open(factory:databaseFactoryFfi,path:'${dir.path}/local.sqlite');await member(store.deviceId,role:'owner');clock=DateTime.utc(2026,1,31,12);routes=PetRoutes(store,now:()=>clock);});
  tearDown(()async{await store.close();await dir.delete(recursive:true);});
  test('档案CRUD/归档/重启保持且宠物不成为家庭成员',()async{
    final row=await pet(),id=row['id'] as String;expect(Pet.fromJson(row).birthdayEstimated,isTrue);
    await call('PATCH',['pets',id],body:{'name':'新名字','notes':'本地记录','neutered':true});
    expect(await store.list(fid,'/families/$fid/members'),hasLength(1));await store.close();store=await LocalStore.open(factory:databaseFactoryFfi,path:'${dir.path}/local.sqlite');routes=PetRoutes(store,now:()=>clock);
    expect(Pet.fromJson(await object('GET',['pets',id])).name,'新名字');final archived=Pet.fromJson(await object('DELETE',['pets',id]));expect(archived.archivedAt,isNotNull);expect((await call('GET',['pets'])).data,isEmpty);await expectLater(call('GET',['pets',id]),error(404));
  });
  test('默认类型一次播种/重命名归档/排序/非法方法无写入',()async{
    final before=await store.vector(fid);await expectLater(call('DELETE',['pet','record-types']),error(405));expect(await store.vector(fid),before);
    final rows=await types();expect(rows,hasLength(10));expect(rows.map(PetRecordType.fromJson).where((t)=>t.isWeight),hasLength(1));
    final id=rows.first['id'] as String;await call('PATCH',['pet','record-types',id],body:{'name':'自己的喂食','archived':true});expect(await types(),hasLength(9));
    final all=(await call('GET',['pet','record-types'],query:{'include_archived':true})).data as List;expect(all,hasLength(10));expect(all.where((r)=>(r as Map)['name']=='喂食'),isEmpty);
    final reversed=rows.reversed.map((r)=>r['id']).toList();await call('PUT',['pet','record-types','order'],body:{'ids':reversed});await expectLater(call('PUT',['pet','record-types','order'],body:{'ids':[id,id]}),error(400));
    await expectLater(call('POST',['pet','record-types'],body:{'name':'体重','emoji':'🐾'}),error(409));
  });
  test('记录真实头像/类型快照/精确体重/仪表盘模型解码',()async{
    final p=await pet(),pid=p['id'] as String,weight=(await types()).firstWhere((r)=>r['data_kind']=='weight'),tid=weight['id'] as String;
    final saved=PetRecord.fromJson(await record(pid,tid,extra:{'weight_kg':4.125}));expect(saved.weightKg,4.125);expect(saved.createdBy,store.deviceId);expect(saved.creatorAvatarUrl,'wo-local-avatar://${store.deviceId}/1');
    final raw=await store.get(fid,'/families/$fid/plugins/pet/records',saved.id);expect(raw!['weight_grams'],4125);expect(raw.containsKey('creator_avatar_url'),isFalse);
    await call('PATCH',['pet','record-types',tid],body:{'name':'称重'});final read=PetRecord.fromJson(await object('GET',['pet','pets',pid,'records',saved.id]));expect(read.typeName,'体重');await call('PATCH',['pet','pets',pid,'records',saved.id],body:{'record_type_id':tid,'note':'只改备注'});expect((await object('GET',['pet','pets',pid,'records',saved.id]))['type_name'],'体重');
    final dashboard=PetDashboard.fromJson(await object('GET',['pet','pets',pid]));expect(dashboard.latestWeight!.weightKg,4.125);expect(dashboard.weightTrend,hasLength(1));expect(dashboard.records.single.id,saved.id);
    final list=(await call('GET',['pet','pets'])).data as List;expect(PetListItem.fromJson(Json.from(list.single as Map)).pet.id,pid);
    for(final invalid in [0,-1,1000.001,1.0001,'NaN']){await expectLater(record(pid,tid,extra:{'weight_kg':invalid}),error(400));}
    await expectLater(call('PATCH',['pet','record-types',tid],body:{'data_kind':'general'}),error(409));
  });
  test('照护完成原子推进/月末闰年/单次计划重试不重复',()async{
    final pid=(await pet())['id'] as String,tid=(await types()).first['id'] as String,p=await plan(pid,tid),planId=p['id'] as String;
    final body={'scheduled_due_date':'2026-01-31','occurred_on':'2026-01-31'};
    final a=await object('POST',['pet','pets',pid,'plans',planId,'completions'],body:body),b=await object('POST',['pet','pets',pid,'plans',planId,'completions'],body:body);expect(b['id'],a['id']);
    final next=PetCarePlan.fromJson(await object('GET',['pet','pets',pid,'plans',planId]));expect(next.nextDueDate,DateTime(2026,2,28));
    final one=await plan(pid,tid,extra:{'recurrence_unit':'none'}),oneId=one['id'] as String;
    final once=await object('POST',['pet','pets',pid,'plans',oneId,'completions'],body:body);expect((await object('GET',['pet','pets',pid,'plans',oneId]))['active'],false);
    expect((await object('POST',['pet','pets',pid,'plans',oneId,'completions'],body:body))['id'],once['id']);
    expect(PetRoutes.advance(DateTime.utc(2024,2,29),'year',1),DateTime.utc(2025,2,28));
    await expectLater(call('POST',['pet','pets',pid,'plans',planId,'completions'],body:{'scheduled_due_date':'2026-01-30'}),error(409));
  });
  test('记录/后续计划同批创建，删计划保留历史且读取移除失效关联',()async{
    final pid=(await pet())['id'] as String,tid=(await types()).first['id'] as String;
    final saved=PetRecord.fromJson(await record(pid,tid,extra:{'follow_up':{'recurrence_unit':'week','recurrence_interval':2,'next_due_date':'2026-02-02'}}));expect(saved.planId,isNotNull);expect(saved.nextDueDate,DateTime(2026,2,2));
    await call('DELETE',['pet','pets',pid,'plans',saved.planId!]);final read=PetRecord.fromJson(await object('GET',['pet','pets',pid,'records',saved.id]));expect(read.planId,isNull);expect(read.name,'记录');
    await call('PATCH',['pet','pets',pid,'records',saved.id],body:{'note':'修改','record_type_id':null});await call('DELETE',['pet','pets',pid,'records',saved.id]);await expectLater(call('GET',['pet','pets',pid,'records',saved.id]),error(404));
  });
  test('按实际日期与稳定ID分页，删锚点仍续页且跨宠物游标拒绝',()async{
    final pid=(await pet())['id'] as String,other=(await pet())['id'] as String,tid=(await types()).first['id'] as String;
    final a=await record(pid,tid,extra:{'occurred_on':'2026-01-10'});await record(pid,tid,extra:{'occurred_on':'2020-01-01'});await record(pid,tid,extra:{'occurred_on':'2026-01-05'});
    final first=await call('GET',['pet','pets',pid,'records'],query:{'limit':1});expect((first.data as List).single['id'],a['id']);expect(first.meta!['total'],3);final cursor=first.meta!['cursor'];
    await call('DELETE',['pet','pets',pid,'records',a['id'] as String]);final rest=await call('GET',['pet','pets',pid,'records'],query:{'cursor':cursor,'limit':'50'});expect((rest.data as List).map((r)=>r['occurred_on']),['2026-01-05','2020-01-01']);
    await expectLater(call('GET',['pet','pets',other,'records'],query:{'cursor':cursor}),error(400));await expectLater(call('GET',['pet','pets',pid,'records'],query:{'limit':51}),error(400));
  });
  test('权限不信任正文作者/外家庭/他人计划，未知方法不假成功',()async{
    final pid=(await pet())['id'] as String,tid=(await types()).first['id'] as String,p=await plan(pid,tid);await member('other-member');
    await store.patch(fid,'/families/$fid/plugins/pet/plans',p['id'] as String,{'created_by':'other-member'});await member(store.deviceId);
    final before=await store.vector(fid);await expectLater(call('PATCH',['pets',pid],body:{'name':'拒绝'}),error(403));await expectLater(call('PATCH',['pet','pets',pid,'plans',p['id'] as String],body:{'name':'拒绝'}),error(403));
    await expectLater(record(pid,tid,extra:{'created_by':'other-member'}),error(400));await expectLater(record(pid,tid,extra:{'follow_up':{'plan_id':p['id'],'next_due_date':'2026-03-01'}}),error(403));expect(await store.vector(fid),before);
    await expectLater(call('GET',['pets'],family:'other-family'),error(403));expect(await routes.request('GET',fid,['pet','unknown']),isNull);
  });
  test('宠物照片及旧上传明确待接，不伪造不存在附件删除',()async{
    final pid=(await pet())['id'] as String,tid=(await types()).first['id'] as String,r=await record(pid,tid),rid=r['id'] as String,before=await store.vector(fid);
    await expectLater(call('POST',['pets',pid,'photo']),error(501));await expectLater(call('DELETE',['pets',pid,'photo']),error(501));
    await expectLater(call('POST',['pet','records',rid,'attachments']),error(501));await expectLater(call('DELETE',['pet','records',rid,'attachments','attachment']),error(404));expect(await store.vector(fid),before);
  });
  test('故障注入完成事务全回滚，重试一次成功',()async{
    final pid=(await pet())['id'] as String,tid=(await types()).first['id'] as String,p=await plan(pid,tid),id=p['id'] as String,before=await store.vector(fid);
    await store.db.execute("CREATE TRIGGER fail_pet_plan BEFORE INSERT ON documents WHEN NEW.collection = '/families/$fid/plugins/pet/plans' BEGIN SELECT RAISE(ABORT, 'synthetic plan persistence failure'); END");
    final body={'scheduled_due_date':'2026-01-31'};await expectLater(call('POST',['pet','pets',pid,'plans',id,'completions'],body:body),throwsA(anything));expect(await store.vector(fid),before);expect(await store.list(fid,'/families/$fid/plugins/pet/records'),isEmpty);
    await store.db.execute('DROP TRIGGER fail_pet_plan');await call('POST',['pet','pets',pid,'plans',id,'completions'],body:body);expect(await store.list(fid,'/families/$fid/plugins/pet/records'),hasLength(1));
  });
  test('仅启用卡片生成待交付提醒，重试去重且不推进计划',()async{
    final pid=(await pet())['id'] as String,tid=(await types()).first['id'] as String,p=await plan(pid,tid);expect(await routes.requestDueReminders(fid),0);
    await store.patch(fid,'/families/$fid/installed','pet-install',{'plugin_id':'pet','enabled':true});expect(await routes.requestDueReminders(fid),1);expect(await routes.requestDueReminders(fid),0);
    final requests=await store.list(fid,'/families/$fid/notifications');expect(requests.single['status'],'pending_local_delivery');expect(requests.single['recipient_ids'],[store.deviceId]);
    expect((await object('GET',['pet','pets',pid,'plans',p['id'] as String]))['next_due_date'],'2026-01-31');await call('DELETE',['pets',pid]);clock=DateTime.utc(2026,2,1);expect(await routes.requestDueReminders(fid),0);
  });
  test('双SQLite离线完成同一计划轮次合并为一个记录',()async{
    final pid=(await pet())['id'] as String,tid=(await types()).first['id'] as String,p=await plan(pid,tid),id=p['id'] as String;
    final peer=await LocalStore.open(factory:databaseFactoryFfi,path:'${dir.path}/peer.sqlite');
    try{
      await member(peer.deviceId);await peer.merge(fid,await store.exportSince(fid,{}));final peerRoutes=PetRoutes(peer,now:()=>clock),body={'scheduled_due_date':'2026-01-31'};
      final left=await object('POST',['pet','pets',pid,'plans',id,'completions'],body:body),right=await peerRoutes.request('POST',fid,['pet','pets',pid,'plans',id,'completions'],body:body);
      expect((right!.data as Map)['id'],left['id']);
      final toPeer=await store.exportSince(fid,await peer.vector(fid)),toLocal=await peer.exportSince(fid,await store.vector(fid));await peer.merge(fid,toPeer);await store.merge(fid,toLocal);
      final a=await store.list(fid,'/families/$fid/plugins/pet/records'),b=await peer.list(fid,'/families/$fid/plugins/pet/records');expect(a,hasLength(1));expect(LocalStore.canonical(a),LocalStore.canonical(b));
    }finally{await peer.close();}
  });

  // 以下为准备好的源码测试；本轮禁止SDK执行，未声称已经运行。
  test('普通附件描述可读但不伪造URL，成员读/作者或owner删并留墓碑',()async{
    final pid=(await pet())['id'] as String,tid=(await types()).first['id'] as String,rid=(await record(pid,tid))['id'] as String;
    final id='a_${List.filled(32,'1').join()}',author=store.deviceId;
    final descriptor=AttachmentDescriptor(id:id,binding:AttachmentBinding(familyId:fid,plugin:'pet',parentId:rid,authorDeviceId:author),
      purpose:'pet_file_copy',kind:'file',displayName:'synthetic-report.pdf',contentType:'application/pdf',size:6,sha256:List.filled(64,'2').join(),createdAt:'2026-01-31T12:00:00.000Z');
    final fields=Json.from(descriptor.toJson())..remove('id');await store.patch(fid,'/families/$fid/plugins/pet/attachments',id,fields);
    final result=PetRecord.fromJson(await object('GET',['pet','pets',pid,'records',rid]));expect(result.attachments.single.url,isEmpty);
    await store.patch(fid,'/families/$fid/plugins/pet/records',rid,{'created_by':'other-member'});await member(store.deviceId);
    expect((await routes.listAttachments(fid,rid)).single.id,id);
    await expectLater(routes.deleteAttachment(fid,rid,id),error(403));expect(await store.get(fid,'/families/$fid/plugins/pet/attachments',id),isNotNull);
    await member(store.deviceId,role:'owner');await routes.deleteAttachment(fid,rid,id);
    expect(await store.get(fid,'/families/$fid/plugins/pet/attachments',id),isNull);expect(await store.revision(fid,'/families/$fid/plugins/pet/attachments',id),greaterThan(0));
  });
  test('父记录删除原子删除附件描述；归档不冒充删除附件；撤权不可读',()async{
    final pid=(await pet())['id'] as String,tid=(await types()).first['id'] as String,rid=(await record(pid,tid))['id'] as String;
    final id='a_${List.filled(32,'3').join()}',descriptor=AttachmentDescriptor(id:id,binding:AttachmentBinding(familyId:fid,plugin:'pet',parentId:rid,authorDeviceId:store.deviceId),
      purpose:'pet_file_copy',kind:'file',displayName:'synthetic.txt',contentType:'text/plain',size:3,sha256:List.filled(64,'4').join(),createdAt:'2026-01-31T12:00:00.000Z');
    await store.patch(fid,'/families/$fid/plugins/pet/attachments',id,Json.from(descriptor.toJson())..remove('id'));
    await store.patch(fid,'/families/$fid/pets',pid,{'archived_at':'2026-01-31T12:00:00.000Z'});
    expect((await routes.listAttachments(fid,rid)).single.id,id);await expectLater(call('DELETE',['pet','pets',pid,'records',rid]),error(404));
    await store.patch(fid,'/families/$fid/pets',pid,{'archived_at':null});await call('DELETE',['pet','pets',pid,'records',rid]);
    expect(await store.get(fid,'/families/$fid/plugins/pet/attachments',id),isNull);await expectLater(routes.listAttachments(fid,rid),error(404));
    await store.patch(fid,'/families/$fid/members',store.deviceId,{'status':'revoked'});await expectLater(routes.listAttachments(fid,rid),error(403));
  });
  test('十件上限在触碰原生选择之前拒绝，未知admin不能提升权限',()async{
    final pid=(await pet())['id'] as String,tid=(await types()).first['id'] as String,rid=(await record(pid,tid))['id'] as String;
    for(var i=0;i<10;i++){
      final id='a_${i.toRadixString(16).padLeft(32,'0')}',descriptor=AttachmentDescriptor(id:id,binding:AttachmentBinding(familyId:fid,plugin:'pet',parentId:rid,authorDeviceId:store.deviceId),
        purpose:'pet_file_copy',kind:'file',displayName:'synthetic-$i.txt',contentType:'text/plain',size:3,sha256:List.filled(64,'5').join(),createdAt:'2026-01-31T12:00:00.000Z');
      await store.patch(fid,'/families/$fid/plugins/pet/attachments',id,Json.from(descriptor.toJson())..remove('id'));
    }
    var opened=false;final withStore=PetRoutes(store,attachmentStore:()async{opened=true;throw StateError('synthetic-provider-must-remain-lazy');});
    await expectLater(withStore.addAttachment(fid,rid,AttachmentSelectionMetadata(token:'11111111-2222-4333-8444-555555555555',purpose:'pet_file_copy',displayName:'synthetic.txt',contentType:'text/plain',size:3,kind:'file')),error(400));expect(opened,isFalse);
    await member(store.deviceId,role:'admin');await expectLater(routes.listAttachments(fid,rid),error(403));
  });

}
