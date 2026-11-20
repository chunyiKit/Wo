import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/local/plugins/calendar_routes.dart';

void main(){
  sqfliteFfiInit();const fid='family-calendar';late Directory directory;late LocalStore store;late CalendarRoutes routes;late DateTime clock;
  Matcher error(int status)=>throwsA(isA<ApiException>().having((e)=>e.statusCode,'status',status));
  Future<void> member(String id)async{await store.patch(fid,'/families/$fid/members',id,{'user_id':id,'family_id':fid,'status':'active','role':'member','display_name':'成员','avatar_emoji':'🐱','avatar_url':'/local/avatar/$id?v=1'});}
  Future<Map<String,dynamic>> item(String method,List<String> tail,{Map<String,dynamic> body=const{}})async{
    final result=await routes.request(method,fid,['calendar','items',...tail],body:body);expect(result,isNotNull);return Map<String,dynamic>.from(result!.data as Map);
  }
  setUp(()async{directory=await Directory.systemTemp.createTemp('wo-calendar-');store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/local.sqlite');await member(store.deviceId);clock=DateTime(2026,11,20,23,59);routes=CalendarRoutes(store,now:()=>clock);});
  tearDown(()async{await store.close();await directory.delete(recursive:true);});
  test('家历CRUD/模型/指派真实头像与重启持久',()async{
    await member('assignee-b');final created=await item('POST',[],body:{'title':' 安排 ','emoji':'📅','note':'备注','event_date':'2026-11-21','all_day':false,'start_minute':540,'assigned_to':'assignee-b','notify_enabled':true,'notify_days_before':1});
    final model=CalendarItem.fromJson(created);expect(model.title,'安排');expect(model.timeLabel,'09:00');expect(model.daysUntil,1);expect(model.assigneeAvatarUrl,'/local/avatar/assignee-b?v=1');expect(model.createdBy,store.deviceId);
    expect(await store.list(fid,'/families/$fid/notifications'),hasLength(1));
    await item('PUT',[model.id],body:{'title':'修改','note':null,'assigned_to':null});
    await store.close();store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/local.sqlite');routes=CalendarRoutes(store,now:()=>clock);
    final read=CalendarItem.fromJson(await item('GET',[model.id]));expect(read.title,'修改');expect(read.note,isNull);expect(read.assignedTo,isNull);expect(read.createdAt,model.createdAt);
    expect((await routes.request('DELETE',fid,['calendar','items',model.id]))!.data,isNull);await expectLater(item('GET',[model.id]),error(404));
  });
  test('显式清除日期规范化为待办，不保留隐性重复/时间/自动提醒',()async{
    final created=await item('POST',[],body:{'title':'待办','event_date':'2026-12-01','all_day':false,'start_minute':1439,'repeat':'weekly','notify_enabled':true,'notify_days_before':3});
    final changed=CalendarItem.fromJson(await item('PUT',[created['id'] as String],body:{'event_date':null}));
    expect(changed.isTodo,isTrue);expect(changed.allDay,isTrue);expect(changed.startMinute,isNull);expect(changed.repeat,'none');expect(changed.notifyEnabled,isFalse);expect(changed.notifyDaysBefore,0);expect(changed.daysUntil,isNull);
    final allDay=CalendarItem.fromJson(await item('PUT',[changed.id],body:{'event_date':'2026-11-25','all_day':true,'start_minute':600}));expect(allDay.startMinute,isNull);
  });
  test('单次完成/重开幂等，重复事项按今天之后实例滚动',()async{
    final one=await item('POST',[],body:{'title':'一次'}),id=one['id'] as String;
    final completed=await item('POST',[id,'complete']);final stamp=completed['completed_at'];clock=clock.add(const Duration(hours:1));
    expect((await item('POST',[id,'complete']))['completed_at'],stamp);expect((await item('POST',[id,'reopen']))['completed_at'],isNull);
    final daily=await item('POST',[],body:{'title':'每天','event_date':'2020-01-01','repeat':'daily'});
    final moved=await item('POST',[daily['id'] as String,'complete']);expect(moved['event_date'],'2026-11-22');expect(moved['done'],isFalse);
    expect((await item('POST',[daily['id'] as String,'complete']))['event_date'],'2026-11-22');
  });
  test('月末31号锚点跨二月不漂移，标题修改不重设锚点',()async{
    clock=DateTime.utc(2026,1,31);
    final jan=await item('POST',[],body:{'title':'月末','event_date':'2026-01-31','repeat':'monthly'}),id=jan['id'] as String;
    expect((await item('POST',[id,'complete']))['event_date'],'2026-02-28');
    await item('PUT',[id],body:{'title':'改标题','event_date':'2026-02-28','repeat':'monthly'});
    expect((await store.get(fid,'/families/$fid/plugins/calendar/items',id))!['repeat_anchor_day'],31);
    clock=DateTime.utc(2026,2,28);expect((await item('POST',[id,'complete']))['event_date'],'2026-03-31');
    expect(CalendarRecurrence.next(DateTime.utc(2020,1,31),'monthly',DateTime.utc(2026,4,30)),DateTime.utc(2026,4,30));
    expect(CalendarRecurrence.advance(DateTime.utc(2020,1,31),'monthly',DateTime.utc(2026,4,30)),DateTime.utc(2026,5,31));
    expect(CalendarRecurrence.next(DateTime.utc(2026,11,16),'weekly',DateTime.utc(2026,11,20)),DateTime.utc(2026,11,23));
  });
  test('列表打开在前、下一日和时间排序，首页不改写派生字段',()async{
    final todo=await item('POST',[],body:{'title':'无日期'});
    final later=await item('POST',[],body:{'title':'晚','event_date':'2026-11-21','all_day':false,'start_minute':600});
    final early=await item('POST',[],body:{'title':'早','event_date':'2026-11-21','all_day':false,'start_minute':540});
    final done=await item('POST',[],body:{'title':'已完成','event_date':'2026-11-19'});await item('POST',[done['id'] as String,'complete']);
    final page=(await routes.request('GET',fid,['calendar','items']))!.data as List;
    expect(page.map((r)=>(r as Map)['id']),[early['id'],later['id'],todo['id'],done['id']]);
    final before=await store.vector(fid);expect((await routes.preview(fid))['primary'],'早');expect(await store.vector(fid),before);
    expect(((await routes.request('GET',fid,['calendar','items'],query:{'done':true}))!.data as List).single['id'],done['id']);
  });
  test('本地提醒与日期窗口去重，明确不是系统送达',()async{
    await member('assignee-b');final created=await item('POST',[],body:{'title':'明天','event_date':'2026-11-21','assigned_to':'assignee-b','notify_enabled':true,'notify_days_before':1});
    final remind=await item('POST',[created['id'] as String,'remind']);expect(remind['status'],'pending_local_delivery');expect(remind['system_delivered'],isFalse);
    expect(await routes.requestDueReminders(fid),1);expect(await routes.requestDueReminders(fid),0);
    final notifications=await store.list(fid,'/families/$fid/notifications');expect(notifications.where((n)=>n['type']=='calendar_due'),hasLength(1));
    await item('POST',[created['id'] as String,'complete']);await expectLater(item('POST',[created['id'] as String,'remind']),error(400));
  });
  test('非法日期/字段/负责人及越权操作拒绝不落库',()async{
    for(final body in <Map<String,dynamic>>[{'title':' '},{'title':'字'*65},{'title':'x','event_date':'2026-02-30'},{'title':'x','start_minute':1440},{'title':'x','repeat':'yearly'},{'title':'x','done':true},{'title':'x','assigned_to':'outside'}]){await expectLater(item('POST',[],body:body),error(400));}
    expect(await store.list(fid,'/families/$fid/plugins/calendar/items'),isEmpty);
    expect(await routes.request('GET',fid,['calendar','unknown']),isNull);
    await expectLater(routes.request('DELETE',fid,['calendar','items']),error(405));
    await store.patch(fid,'/families/$fid/members',store.deviceId,{'status':'left'});await expectLater(routes.request('GET',fid,['calendar','items']),error(403));
  });
  test('指派事务的通知写入失败不留下任务与序号',()async{
    await member('assignee-b');await store.db.execute("CREATE TRIGGER reject_calendar_notification BEFORE INSERT ON documents WHEN NEW.collection = '/families/$fid/notifications' BEGIN SELECT RAISE(ABORT, 'calendar notification synthetic failure'); END");
    final before=await store.vector(fid);
    await expectLater(item('POST',[],body:{'title':'事务','assigned_to':'assignee-b'}),throwsA(predicate((e)=>'$e'.contains('calendar notification synthetic failure'))));
    expect(await store.list(fid,'/families/$fid/plugins/calendar/items'),isEmpty);expect(await store.vector(fid),before);
  });
}
