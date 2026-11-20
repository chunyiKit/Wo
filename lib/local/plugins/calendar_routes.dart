import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../local_backend.dart';
import '../local_store.dart';

class CalendarRoutes {
  CalendarRoutes(this.store,{DateTime Function()? now}):_now=now??DateTime.now;
  final LocalStore store;
  final DateTime Function() _now;
  static const _uuid=Uuid();
  static const _fields={'title','note','emoji','event_date','all_day','start_minute','repeat','assigned_to','notify_enabled','notify_days_before'};
  static const syncFields=<String,Set<String>>{
    'plugins/calendar/items':{'family_id','created_by','created_at','title','note','emoji','event_date','all_day','start_minute','repeat','repeat_anchor_day','assigned_to','notify_enabled','notify_days_before','done','completed_at'},
    'notifications':{'type','title','body','icon_emoji','created_by','created_at','read_by','status','recipient_ids','source_plugin','source_id','source_occurrence'},
  };
  static final _id=RegExp(r'^[A-Za-z0-9_-]{1,100}$');
  static final _queues=Expando<Map<String,Future<void>>>();
  String _col(String fid)=>'/families/$fid/plugins/calendar/items';
  String get _stamp=>_now().toUtc().toIso8601String();
  DateTime get _today{final n=_now();return DateTime.utc(n.year,n.month,n.day);}
  static Never _fail(int status,String text)=>throw ApiException(switch(status){403=>'FORBIDDEN',404=>'NOT_FOUND',405=>'METHOD_NOT_ALLOWED',_=>'VALIDATION_ERROR'},text,statusCode:status);
  static void _only(Json map,Set<String> allowed){if(map.keys.any((key)=>!allowed.contains(key)))_fail(400,'包含未知或只读字段');}
  static String _text(Object? value,int max){if(value is! String||value.trim().isEmpty||value.runes.length>max)_fail(400,'文本为空或过长');return value.trim();}
  static bool _bool(Object? value){if(value is! bool)_fail(400,'开关必须是true/false');return value;}
  static int _int(Object? value,int min,int max){if(value is! int||value<min||value>max)_fail(400,'数值超出范围');return value;}
  static String _format(DateTime d)=>[d.year.toString().padLeft(4,'0'),d.month.toString().padLeft(2,'0'),d.day.toString().padLeft(2,'0')].join('-');
  static String _date(Object? value){
    if(value is! String||!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value))_fail(400,'日期必须是YYYY-MM-DD');
    final parsed=DateTime.tryParse(value);if(parsed==null||parsed.year<1||parsed.year>9999||_format(parsed)!=value)_fail(400,'日期不存在');return value;
  }
  Future<Json> _member(String fid,[String? recipient])async{
    final id=recipient??store.deviceId;if(!_id.hasMatch(fid)||!_id.hasMatch(id))_fail(400,'家庭或成员标识无效');
    final m=await store.get(fid,'/families/$fid/members',id);
    if(m==null||m['status']!='active'||m['user_id']!=id||m['family_id']!=fid)_fail(recipient==null?403:400,'家庭成员身份无效');return m;
  }
  Future<T> _serial<T>(String fid,Future<T> Function() action){
    final queues=_queues[store]??=<String,Future<void>>{},done=Completer<T>();
    queues[fid]=(queues[fid]??Future<void>.value()).then((_)async{try{done.complete(await action());}catch(e,s){done.completeError(e,s);}});return done.future;
  }
  Future<Json> _load(String fid,String id)async{
    if(!_id.hasMatch(id))_fail(400,'记录标识无效');final row=await store.get(fid,_col(fid),id);if(row==null||row['family_id']!=fid)_fail(404,'日程不存在');return row;
  }
  Future<List<Json>> _rows(String fid)async=>[for(final row in await store.list(fid,_col(fid)))if(row['family_id']==fid)row];
  Future<LocalResult?> request(String method,String fid,List<String> tail,{Json body=const{},Json query=const{}})async{
    if(tail.length<2||tail[0]!='calendar'||tail[1]!='items'||!(tail.length==2||tail.length==3||(tail.length==4&&['complete','reopen','remind'].contains(tail[3]))))return null;
    await _member(fid);final verb=method.toUpperCase();
    if(verb=='GET')return _request(verb,fid,tail,body,query);
    return _serial(fid,()=>_request(verb,fid,tail,body,query));
  }
  Future<Json> _values(String fid,Json body,{Json? old})async{
    _only(body,_fields);final create=old==null,fields=<String,dynamic>{};
    if(create||body.containsKey('title'))fields['title']=_text(body['title'],64);
    if(create||body.containsKey('emoji'))fields['emoji']=_text(body.containsKey('emoji')?body['emoji']:'📅',16);
    if(create||body.containsKey('note')){
      final note=body['note'];if(note!=null&&(note is! String||note.runes.length>500))_fail(400,'备注过长或无效');fields['note']=note;
    }
    if(create||body.containsKey('event_date'))fields['event_date']=body['event_date']==null?null:_date(body['event_date']);
    for(final key in ['all_day','notify_enabled']){if(create||body.containsKey(key))fields[key]=_bool(body.containsKey(key)?body[key]:key=='all_day');}
    if(create||body.containsKey('start_minute'))fields['start_minute']=body['start_minute']==null?null:_int(body['start_minute'],0,1439);
    if(create||body.containsKey('notify_days_before'))fields['notify_days_before']=_int(body.containsKey('notify_days_before')?body['notify_days_before']:0,0,365);
    if(create||body.containsKey('repeat')){final rule=body.containsKey('repeat')?body['repeat']:'none';if(!['none','daily','weekly','monthly'].contains(rule))_fail(400,'重复规则无效');fields['repeat']=rule;}
    if(create||body.containsKey('assigned_to')){final id=body['assigned_to'];if(id!=null){if(id is! String)_fail(400,'负责人标识无效');await _member(fid,id);}fields['assigned_to']=id;}
    final combined=<String,dynamic>{...?old,...fields};
    if(combined['event_date']==null){combined.addAll({'repeat':'none','all_day':true,'start_minute':null,'notify_enabled':false,'notify_days_before':0,'repeat_anchor_day':null});}
    else{
      if(combined['all_day']==true)combined['start_minute']=null;
      final changedDate=old!=null&&body.containsKey('event_date')&&fields['event_date']!=old['event_date'];
      final changedRule=old!=null&&body.containsKey('repeat')&&fields['repeat']!=old['repeat'];
      combined['repeat_anchor_day']=combined['repeat']=='monthly'?
        (create||changedDate||changedRule||old?['repeat_anchor_day']==null?DateTime.parse(combined['event_date'] as String).day:old!['repeat_anchor_day']):null;
    }
    return {for(final key in {..._fields,'repeat_anchor_day'})if(create||combined[key]!=old![key])key:combined[key]};
  }
  Future<Json?> _assignee(String fid,Object? id)async{
    if(id is! String||!_id.hasMatch(id))return null;final m=await store.get(fid,'/families/$fid/members',id);
    return m!=null&&m['status']=='active'&&m['family_id']==fid&&m['user_id']==id?m:null;
  }
  Future<Json> _read(String fid,Json row)async{
    final assignee=await _assignee(fid,row['assigned_to']);
    final next=row['event_date']==null?null:CalendarRecurrence.next(DateTime.parse(row['event_date'] as String),row['repeat'] as String,_today,anchorDay:row['repeat_anchor_day'] as int?);
    return {'id':row['id'],'family_id':fid,for(final key in _fields)key:row[key],
      'done':row['done'],'completed_at':row['completed_at'],'created_by':row['created_by'],'created_at':row['created_at'],
      'next_date':next==null?null:_format(next),'days_until':next?.difference(_today).inDays,
      'assignee_name':assignee?['display_name'],'assignee_emoji':assignee?['avatar_emoji'],'assignee_avatar_url':assignee?['avatar_url']};
  }
  Future<Json> _notification(String fid,Json row,String type,List<String> recipients,{String? occurrence})async{
    final actor=await _member(fid);final name=actor['display_name'] is String?String.fromCharCodes((actor['display_name'] as String).runes.take(80)):'家庭成员';
    return {'type':type,'title':type=='calendar_assigned'?'你有一项新安排：${row['title']}':type=='calendar_due'?'日程到期提醒：${row['title']}':'记得：${row['title']}',
      'body':type=='calendar_assigned'?'$name 把这件事交给了你':type=='calendar_due'?'请查看本机日程的日期与时间':'$name 提醒你这件事',
      'icon_emoji':row['emoji'],'created_by':store.deviceId,'created_at':_stamp,'read_by':<String>[],'status':'pending_local_delivery',
      'recipient_ids':recipients,'source_plugin':'calendar','source_id':row['id'],if(occurrence!=null)'source_occurrence':occurrence};
  }
  Future<LocalResult> _request(String verb,String fid,List<String> tail,Json body,Json query)async{
    _only(query,tail.length==2&&verb=='GET'?{'done'}:<String>{});
    if(tail.length==2){
      if(verb=='GET'){
        bool? done;if(query.containsKey('done')){final raw=query['done'];if(raw is bool){done=raw;}else if(raw is String&&['true','false'].contains(raw.toLowerCase())){done=raw.toLowerCase()=='true';}else{_fail(400,'完成筛选无效');}}
        final rows=[for(final row in await _rows(fid))if(done==null||row['done']==done)await _read(fid,row)];
        rows.sort(_compare);return(data:rows,meta:null);
      }
      if(verb!='POST')_fail(405,'此路由不支持该方法');
      final values=await _values(fid,body),id=_uuid.v4();final fields={'family_id':fid,'created_by':store.deviceId,'created_at':_stamp,'done':false,'completed_at':null,...values};
      final assigned=fields['assigned_to'];final notification=assigned is String&&assigned!=store.deviceId?await _notification(fid,{'id':id,...fields},'calendar_assigned',[assigned]):null;
      await store.batch([{'space':fid,'collection':_col(fid),'id':id,'fields':fields},if(notification!=null){'space':fid,'collection':'/families/$fid/notifications','id':_uuid.v4(),'fields':notification}]);
      return(data:await _read(fid,await _load(fid,id)),meta:null);
    }
    final row=await _load(fid,tail[2]);
    if(tail.length==4){
      if(verb!='POST')_fail(405,'状态操作需要POST');_only(body,<String>{});
      if(tail[3]=='remind'){
        final assigned=row['assigned_to'];if(assigned is! String||row['done']==true)_fail(400,'提醒需要有效负责人且事项未完成');await _member(fid,assigned);
        final id=_uuid.v4();await store.patch(fid,'/families/$fid/notifications',id,await _notification(fid,row,'calendar_remind',[assigned]));
        return(data:{'reminded':assigned,'notification_id':id,'status':'pending_local_delivery','system_delivered':false},meta:null);
      }
      final changes=<String,dynamic>{};
      if(tail[3]=='reopen'){if(row['done']==true)changes.addAll({'done':false,'completed_at':null});}
      else if(row['event_date']!=null&&row['repeat']!='none'){
        final next=CalendarRecurrence.advance(DateTime.parse(row['event_date'] as String),row['repeat'] as String,_today,anchorDay:row['repeat_anchor_day'] as int?);
        if(_format(next)!=row['event_date']||row['done']==true)changes.addAll({'event_date':_format(next),'done':false,'completed_at':null});
      }else if(row['done']!=true){changes.addAll({'done':true,'completed_at':_stamp});}
      if(changes.isNotEmpty)await store.patch(fid,_col(fid),tail[2],changes);
      return(data:await _read(fid,await _load(fid,tail[2])),meta:null);
    }
    if(verb=='GET')return(data:await _read(fid,row),meta:null);
    if(verb=='DELETE'){_only(body,<String>{});await store.patch(fid,_col(fid),tail[2],{},delete:true);return(data:null,meta:null);}
    if(!['PUT','PATCH'].contains(verb))_fail(405,'此路由不支持该方法');
    final changes=await _values(fid,body,old:row);final next={...row,...changes};
    final assigned=next['assigned_to'];final notification=changes.containsKey('assigned_to')&&assigned is String&&assigned!=store.deviceId?await _notification(fid,next,'calendar_assigned',[assigned]):null;
    if(changes.isNotEmpty)await store.batch([{'space':fid,'collection':_col(fid),'id':tail[2],'fields':changes},if(notification!=null){'space':fid,'collection':'/families/$fid/notifications','id':_uuid.v4(),'fields':notification}]);
    return(data:await _read(fid,await _load(fid,tail[2])),meta:null);
  }
  static int _compare(Json a,Json b){
    final done=(a['done']==true?1:0)-(b['done']==true?1:0);if(done!=0)return done;
    final date=(a['next_date'] as String? ?? '9999-12-31').compareTo(b['next_date'] as String? ?? '9999-12-31');if(date!=0)return date;
    final time=(a['start_minute'] as int? ?? -1)-(b['start_minute'] as int? ?? -1);return time!=0?time:(a['id'] as String).compareTo(b['id'] as String);
  }
  Future<Json> preview(String fid)async{
    await _member(fid);final rows=[for(final row in await _rows(fid))if(row['done']!=true)await _read(fid,row)];rows.sort(_compare);
    if(rows.isEmpty)return {'primary':'还没有安排','secondary':'点击添加第一件事','color_token':'calendar','emoji':'📅'};
    final first=rows.first,days=first['days_until'] as int?;
    if(days==null)return {'primary':'${rows.length} 件待办','secondary':'还没排到具体哪天','color_token':'calendar','emoji':'📝'};
    return {'primary':first['title'],'secondary':days<0?'已过期 ${-days} 天':days==0?'就在今天':days==1?'明天':'还有 $days 天','color_token':'calendar','emoji':first['emoji'],'secondary_tone':days<0?'danger':days==0?'warning':null};
  }
  Future<int> requestDueReminders(String fid)=>_serial(fid,()async{
    await _member(fid);final members=await store.list(fid,'/families/$fid/members');final recipients=[for(final m in members)if(m['family_id']==fid&&m['status']=='active'&&m['user_id'] is String&&m['id']==m['user_id'])m['user_id'] as String];
    var count=0;
    for(final row in await _rows(fid)){
      if(row['done']==true||row['notify_enabled']!=true||row['event_date']==null)continue;
      final read=await _read(fid,row),delta=read['days_until'] as int;if(delta<0||delta>(row['notify_days_before'] as int))continue;
      final occurrence=read['next_date'] as String,id=_uuid.v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8','calendar:$fid:${row['id']}:$occurrence');
      if(await store.revision(fid,'/families/$fid/notifications',id)>0)continue;
      await store.patch(fid,'/families/$fid/notifications',id,await _notification(fid,row,'calendar_due',recipients,occurrence:occurrence));count++;
    }
    return count;
  });
}

/// 月末锚点独立于当前实例保存，31号不会经过二月后永久漂移成28号。
class CalendarRecurrence {
  static DateTime _day(DateTime d)=>DateTime.utc(d.year,d.month,d.day);
  static DateTime _month(int year,int month,int day){final last=DateTime.utc(year,month+1,0).day;return DateTime.utc(year,month,day>last?last:day);}
  static DateTime next(DateTime anchor,String rule,DateTime today,{int? anchorDay}){
    anchor=_day(anchor);today=_day(today);if(rule=='none'||!anchor.isBefore(today))return anchor;
    if(rule=='daily')return today;
    if(rule=='weekly')return today.add(Duration(days:(anchor.weekday-today.weekday+7)%7));
    if(rule=='monthly'){
      var candidate=_month(today.year,today.month,anchorDay??anchor.day);
      if(candidate.isBefore(today))candidate=_month(today.month==12?today.year+1:today.year,today.month==12?1:today.month+1,anchorDay??anchor.day);
      return candidate;
    }
    throw const FormatException('重复规则无效');
  }
  static DateTime advance(DateTime anchor,String rule,DateTime today,{int? anchorDay}){
    today=_day(today);final candidate=next(anchor,rule,today,anchorDay:anchorDay);if(candidate.isAfter(today))return candidate;
    if(rule=='daily')return today.add(const Duration(days:1));if(rule=='weekly')return today.add(const Duration(days:7));
    if(rule=='monthly')return _month(today.month==12?today.year+1:today.year,today.month==12?1:today.month+1,anchorDay??anchor.day);
    return today;
  }
}
