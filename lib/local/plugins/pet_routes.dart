import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../local_backend.dart';
import '../local_store.dart';
import '../attachments/attachment_descriptor.dart';
import '../attachments/ordinary_attachment_store.dart';

/// 宠物身份不是家庭成员，不参与鉴权；档案/计划/记录均以本机SQLite为事实源。
class PetRoutes {
  PetRoutes(this.store,{this.attachments,this.attachmentStore,DateTime Function()? now}):_now=now??DateTime.now;
  final OrdinaryAttachmentStore? attachments;
  final Future<OrdinaryAttachmentStore> Function()? attachmentStore;
  final LocalStore store;
  final DateTime Function() _now;
  static const _uuid=Uuid(),_namespace='6ba7b811-9dad-11d1-80b4-00c04fd430c8';
  static const _defaults=[('喂食','🍚','general'),('遛狗','🦮','general'),('铲砂','🧹','general'),('喂药','💊','general'),('驱虫','🛡️','general'),('疫苗','💉','general'),('体检','🩺','general'),('体重','⚖️','weight'),('洗护','🫧','general'),('其他','🐾','general')];
  static const _petFields={'name','emoji','species','breed','sex','birthday','birthday_estimated','arrival_date','neutered','notes'};
  static const syncFields=<String,Set<String>>{
    'pets':{'family_id','name','emoji','species','breed','sex','birthday','birthday_estimated','arrival_date','neutered','notes','created_by','created_at','archived_at'},
    'plugins/pet/record-types':{'family_id','name','emoji','data_kind','sort_order','archived_at','created_at'},
    'plugins/pet/settings':{'seeded'},
    'plugins/pet/plans':{'family_id','pet_id','record_type_id','name','note','recurrence_unit','recurrence_interval','next_due_date','active','created_by','created_at','updated_at'},
    'plugins/pet/records':{'family_id','pet_id','record_type_id','type_name_snapshot','type_emoji_snapshot','data_kind_snapshot','name','note','occurred_on','next_due_date','weight_grams','plan_id','scheduled_due_date','created_by','created_at','updated_at'},
    'plugins/pet/attachments': AttachmentDescriptor.syncFields,
    'notifications':{'type','title','body','icon_emoji','created_by','created_at','read_by','status','recipient_ids','source_plugin','source_id','source_occurrence'},
  };
  static final _id=RegExp(r'^[A-Za-z0-9_-]{1,100}$');
  static final _queues=Expando<Map<String,Future<void>>>();
  String _col(String fid,String name)=>name=='pets'?'/families/$fid/pets':'/families/$fid/plugins/pet/$name';
  String get _stamp=>_now().toUtc().toIso8601String();
  DateTime get _today{final n=_now();return DateTime.utc(n.year,n.month,n.day);}
  static Never _fail(int status,String message)=>throw ApiException(switch(status){403=>'FORBIDDEN',404=>'NOT_FOUND',405=>'METHOD_NOT_ALLOWED',409=>'CONFLICT',501=>'FEATURE_UNAVAILABLE',_=>'VALIDATION_ERROR'},message,statusCode:status);
  static void _only(Json map,Set<String> fields){if(map.keys.any((key)=>!fields.contains(key)))_fail(400,'包含未知或只读字段');}
  static void _identifier(String id){if(!_id.hasMatch(id)||_id.firstMatch(id)!.end!=id.length)_fail(400,'标识无效');}
  static String _text(Object? value,int max){if(value is! String||value.trim().isEmpty||value.runes.length>max)_fail(400,'名称为空或过长');return value.trim();}
  static String? _optional(Object? value,int max){if(value==null)return null;if(value is! String||value.runes.length>max)_fail(400,'文本无效或过长');return value;}
  static bool _bool(Object? value){if(value is! bool)_fail(400,'开关必须是true/false');return value;}
  static int _int(Object? value,int min,int max){if(value is! int||value<min||value>max)_fail(400,'数值超出范围');return value;}
  static bool? _filter(Object? value){if(value==null)return null;if(value is bool)return value;if(value is String&&['true','false'].contains(value.toLowerCase()))return value.toLowerCase()=='true';_fail(400,'筛选无效');}
  static String day(DateTime d)=>[d.year.toString().padLeft(4,'0'),d.month.toString().padLeft(2,'0'),d.day.toString().padLeft(2,'0')].join('-');
  static String _date(Object? value){if(value is! String||!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value))_fail(400,'日期必须为YYYY-MM-DD');final d=DateTime.tryParse(value);if(d==null||d.year<1||d.year>9999||day(d)!=value)_fail(400,'日期不存在');return value;}
  Future<Json> _member(String fid)async{_identifier(fid);final m=await store.get(fid,'/families/$fid/members',store.deviceId);if(m==null||m['status']!='active'||m['family_id']!=fid||m['user_id']!=store.deviceId||!{'owner','member'}.contains(m['role']))_fail(403,'本机没有有效家庭成员身份');return m;}
  static void _admin(Json member){if(member['role']!='owner')_fail(403,'只有家庭管理员可以管理宠物档案和记录类型');}
  Future<void> _creator(String fid,Json row)async{final m=await _member(fid);if(m['role']!='owner'&&row['created_by']!=store.deviceId)_fail(403,'只能修改自己创建的内容');}
  Future<T> _serial<T>(String fid,Future<T> Function() action){final queues=_queues[store]??=<String,Future<void>>{},done=Completer<T>();queues[fid]=(queues[fid]??Future<void>.value()).then((_)async{try{done.complete(await action());}catch(e,s){done.completeError(e,s);}});return done.future;}
  Future<List<Json>> _rows(String fid,String name)async=>[for(final row in await store.list(fid,_col(fid,name)))if(row['family_id']==fid)row];
  Future<Json> _load(String fid,String name,String id,{String? petId,bool archived=false})async{_identifier(id);final row=await store.get(fid,_col(fid,name),id);if(row==null||row['family_id']!=fid||petId!=null&&row['pet_id']!=petId||name=='pets'&&!archived&&row['archived_at']!=null)_fail(404,'宠物资料不存在');return row;}
  Future<LocalResult?> request(String method,String fid,List<String> tail,{Json body=const{},Json query=const{}})async{
    if(tail.isEmpty)return null;
    final core=tail[0]=='pets'&&(tail.length<=2||tail.length==3&&tail[2]=='photo');
    final types=tail.length>=2&&tail[0]=='pet'&&tail[1]=='record-types'&&tail.length<=3;
    final pets=tail.length>=2&&tail[0]=='pet'&&tail[1]=='pets'&&(tail.length<=3||tail.length==4&&['plans','records','weights'].contains(tail[3])||tail.length==5&&['plans','records'].contains(tail[3])||tail.length==6&&tail[3]=='plans'&&tail[5]=='completions');
    final attachment=tail.length>=4&&tail[0]=='pet'&&tail[1]=='records'&&tail[3]=='attachments'&&tail.length<=5;
    if(!core&&!types&&!pets&&!attachment)return null;
    await _member(fid);final verb=method.toUpperCase();
    // 类型首次GET会初始化默认字典，也必须与写操作串行。
    if(verb=='GET'&&!types)return _request(verb,fid,tail,body,query);
    return _serial(fid,()=>_request(verb,fid,tail,body,query));
  }
  Json _petRead(Json row)=>{'id':row['id'],'family_id':row['family_id'],for(final key in _petFields)key:row[key],
    'created_by':row['created_by'],'created_at':row['created_at'],'archived_at':row['archived_at'],'photo_url':null,'photo_version':0,'photo_pending':true};
  Json _petValues(Json body,{required bool create}){
    _only(body,_petFields);final values=<String,dynamic>{};
    if(create||body.containsKey('name'))values['name']=_text(body['name'],24);
    if(create||body.containsKey('emoji'))values['emoji']=_text(body.containsKey('emoji')?body['emoji']:'🐾',16);
    for(final entry in {'species':32,'breed':64,'sex':16,'notes':1000}.entries){if(create||body.containsKey(entry.key))values[entry.key]=_optional(body[entry.key],entry.value);}
    for(final key in ['birthday','arrival_date']){if(create||body.containsKey(key))values[key]=body[key]==null?null:_date(body[key]);}
    if(create||body.containsKey('birthday_estimated'))values['birthday_estimated']=_bool(body.containsKey('birthday_estimated')?body['birthday_estimated']:false);
    if(create||body.containsKey('neutered'))values['neutered']=body['neutered']==null?null:_bool(body['neutered']);return values;
  }
  Future<LocalResult> _identity(String verb,String fid,List<String> tail,Json body,Json query)async{
    _only(query,<String>{});
    if(tail.length==1){
      if(verb=='GET'){final rows=(await _rows(fid,'pets')).where((p)=>p['archived_at']==null).toList();rows.sort((a,b){final time=DateTime.parse(a['created_at'] as String).compareTo(DateTime.parse(b['created_at'] as String));return time!=0?time:(a['id'] as String).compareTo(b['id'] as String);});return(data:rows.map(_petRead).toList(),meta:null);}
      if(verb!='POST')_fail(405,'宠物列表不支持该方法');_admin(await _member(fid));final values=_petValues(body,create:true),id=_uuid.v4();await store.patch(fid,_col(fid,'pets'),id,{...values,'family_id':fid,'created_by':store.deviceId,'created_at':_stamp,'archived_at':null});return(data:_petRead(await _load(fid,'pets',id)),meta:null);
    }
    final pet=await _load(fid,'pets',tail[1],archived:tail.length==3&&verb=='GET');
    if(tail.length==3){if(verb!='GET')_admin(await _member(fid));_fail(501,'宠物照片本地文件绑定尚未接入，未上传或假删照片');}
    if(verb=='GET')return(data:_petRead(pet),meta:null);_admin(await _member(fid));
    if(verb=='DELETE'){_only(body,<String>{});await store.patch(fid,_col(fid,'pets'),tail[1],{'archived_at':_stamp});return(data:_petRead(await _load(fid,'pets',tail[1],archived:true)),meta:null);}
    if(!['PATCH','PUT'].contains(verb))_fail(405,'宠物档案不支持该方法');final fields=_petValues(body,create:false);if(fields.isNotEmpty)await store.patch(fid,_col(fid,'pets'),tail[1],fields);return(data:_petRead(await _load(fid,'pets',tail[1])),meta:null);
  }
  Future<void> _seedTypes(String fid)async{
    if((await store.get(fid,_col(fid,'settings'),'types'))?['seeded']==true)return;
    final rows=await _rows(fid,'record-types');final changes=<Json>[];
    for(var i=0;i<_defaults.length;i++){
      final entry=_defaults[i];if(rows.any((row)=>row['name']==entry.$1))continue;
      final id=_uuid.v5(_namespace,'pet-default:$fid:${entry.$1}');if(await store.revision(fid,_col(fid,'record-types'),id)>0)continue;
      changes.add({'space':fid,'collection':_col(fid,'record-types'),'id':id,'fields':{'family_id':fid,'name':entry.$1,'emoji':entry.$2,'data_kind':entry.$3,'sort_order':i,'archived_at':null,'created_at':_stamp}});
    }
    changes.add({'space':fid,'collection':_col(fid,'settings'),'id':'types','fields':{'seeded':true}});await store.batch(changes);
  }
  Future<Json> _type(String fid,String id,{bool active=true})async{final type=await _load(fid,'record-types',id);if(active&&type['archived_at']!=null)_fail(404,'记录类型已归档');return type;}
  Json _typeRead(Json row,{bool conflict=false})=>{'id':row['id'],'family_id':row['family_id'],'name':row['name'],'emoji':row['emoji'],'data_kind':row['data_kind'],'sort_order':row['sort_order'],'archived':row['archived_at']!=null,'name_conflict':conflict};
  Future<LocalResult> _types(String verb,String fid,List<String> tail,Json body,Json query)async{
    if(verb=='GET'&&tail.length==2){_only(query,{'include_archived'});_filter(query['include_archived']);await _seedTypes(fid);}final rows=await _rows(fid,'record-types');
    if(tail.length==2){
      if(verb=='GET'){_only(query,{'include_archived'});final archived=_filter(query['include_archived'])??false;final filtered=rows.where((r)=>archived||r['archived_at']==null).toList();filtered.sort((a,b){final order=(a['sort_order'] as int).compareTo(b['sort_order'] as int);return order!=0?order:(a['id'] as String).compareTo(b['id'] as String);});return(data:[for(final row in filtered)_typeRead(row,conflict:rows.where((r)=>r['name']==row['name']).length>1)],meta:null);}
      _only(query,<String>{});if(verb!='POST')_fail(405,'类型不支持该方法');_admin(await _member(fid));_only(body,{'name','emoji','data_kind'});
      final name=_text(body['name'],32),kind=body.containsKey('data_kind')?body['data_kind']:'general';if(!['general','weight'].contains(kind))_fail(400,'数据能力无效');if(rows.any((r)=>r['name']==name))_fail(409,'记录类型名称已存在');
      final order=rows.fold<int>(-1,(max,row)=>(row['sort_order'] as int)>max?row['sort_order'] as int:max)+1,id=_uuid.v4();
      await store.patch(fid,_col(fid,'record-types'),id,{'family_id':fid,'name':name,'emoji':_text(body.containsKey('emoji')?body['emoji']:'🐾',16),'data_kind':kind,'sort_order':order,'archived_at':null,'created_at':_stamp});return(data:_typeRead(await _type(fid,id)),meta:null);
    }
    _only(query,<String>{});_admin(await _member(fid));
    if(tail[2]=='order'){
      if(verb!='PUT')_fail(405,'类型排序需要PUT');_only(body,{'ids'});final ids=body['ids'];if(ids is! List||ids.any((id)=>id is! String)||ids.toSet().length!=ids.length||!ids.every((id)=>rows.any((row)=>row['id']==id)))_fail(400,'排序包含无效或重复类型');
      if(ids.length>256)_fail(400,'单次排序最多256项');await store.batch([for(var i=0;i<ids.length;i++){'space':fid,'collection':_col(fid,'record-types'),'id':ids[i],'fields':{'sort_order':i}}]);return(data:[for(final id in ids)_typeRead(await _type(fid,id as String,active:false))],meta:null);
    }
    if(verb!='PATCH')_fail(405,'类型修改需要PATCH');final row=await _type(fid,tail[2],active:false);_only(body,{'name','emoji','data_kind','sort_order','archived'});final values=<String,dynamic>{};
    if(body.containsKey('name')){final name=_text(body['name'],32);if(rows.any((r)=>r['id']!=row['id']&&r['name']==name))_fail(409,'类型名称已存在');values['name']=name;}
    if(body.containsKey('emoji'))values['emoji']=_text(body['emoji'],16);
    if(body.containsKey('data_kind')){final kind=body['data_kind'];if(!['general','weight'].contains(kind))_fail(400,'数据能力无效');if(kind!=row['data_kind']&&(await _rows(fid,'records')).any((r)=>r['record_type_id']==row['id']))_fail(409,'已有记录引用类型，不能修改数据能力');values['data_kind']=kind;}
    if(body.containsKey('sort_order'))values['sort_order']=_int(body['sort_order'],0,2147483647);
    if(body.containsKey('archived'))values['archived_at']=_bool(body['archived'])?row['archived_at']??_stamp:null;
    if(values.isNotEmpty)await store.patch(fid,_col(fid,'record-types'),tail[2],values);return(data:_typeRead(await _type(fid,tail[2],active:false)),meta:null);
  }
  Future<Json> _planRead(String fid,Json row)async{
    final type=await _type(fid,row['record_type_id'] as String,active:false);final due=row['next_due_date'];
    final date=due==null?null:DateTime.parse(due as String);return {'id':row['id'],'family_id':fid,'pet_id':row['pet_id'],'record_type_id':type['id'],'type_name':type['name'],'type_emoji':type['emoji'],'data_kind':type['data_kind'],
      'name':row['name'],'note':row['note'],'recurrence_unit':row['recurrence_unit'],'recurrence_interval':row['recurrence_interval'],'next_due_date':due,'active':row['active'],
      'created_by':row['created_by'],'created_at':row['created_at'],'updated_at':row['updated_at'],'days_until':date==null?null:DateTime.utc(date.year,date.month,date.day).difference(_today).inDays};
  }
  Future<Json> _planValues(String fid,Json body,{Json? old})async{
    _only(body,{'record_type_id','name','note','recurrence_unit','recurrence_interval','next_due_date',if(old!=null)'active'});final create=old==null,fields=<String,dynamic>{};
    if(create||body.containsKey('record_type_id')){final id=body['record_type_id'];if(id is! String)_fail(400,'记录类型必填');await _type(fid,id,active:create||id!=(old?['record_type_id']));fields['record_type_id']=id;}
    if(create||body.containsKey('name'))fields['name']=_text(body['name'],80);
    if(create||body.containsKey('note'))fields['note']=_optional(body['note'],2000);
    if(create||body.containsKey('recurrence_unit')){final unit=body.containsKey('recurrence_unit')?body['recurrence_unit']:'none';if(!['none','day','week','month','year'].contains(unit))_fail(400,'周期单位无效');fields['recurrence_unit']=unit;}
    if(create||body.containsKey('recurrence_interval'))fields['recurrence_interval']=_int(body.containsKey('recurrence_interval')?body['recurrence_interval']:1,1,999);
    if(create||body.containsKey('next_due_date'))fields['next_due_date']=body['next_due_date']==null?null:_date(body['next_due_date']);
    if(create||body.containsKey('active'))fields['active']=create?true:_bool(body['active']);
    if(({...?old,...fields})['active']==true&&({...?old,...fields})['next_due_date']==null)_fail(400,'启用计划必须设置下次日期');return fields;
  }
  Future<List<Json>> _plans(String fid,String petId,{bool? active})async{
    final rows=[for(final row in await _rows(fid,'plans'))if(row['pet_id']==petId&&(active==null||row['active']==active))row];rows.sort((a,b){final state=(b['active']==true?1:0)-(a['active']==true?1:0);if(state!=0)return state;final date=(a['next_due_date'] as String? ?? '9999-12-31').compareTo(b['next_due_date'] as String? ?? '9999-12-31');return date!=0?date:(a['id'] as String).compareTo(b['id'] as String);});return rows;
  }
  Future<LocalResult> _planRequest(String verb,String fid,String petId,List<String> tail,Json body,Json query)async{
    if(tail.length==4){
      if(verb=='GET'){_only(query,{'active'});return(data:[for(final row in await _plans(fid,petId,active:_filter(query['active'])))await _planRead(fid,row)],meta:null);}
      _only(query,<String>{});if(verb!='POST')_fail(405,'计划列表不支持该方法');final fields=await _planValues(fid,body),id=_uuid.v4(),stamp=_stamp;
      await store.patch(fid,_col(fid,'plans'),id,{...fields,'family_id':fid,'pet_id':petId,'created_by':store.deviceId,'created_at':stamp,'updated_at':stamp});return(data:await _planRead(fid,await _load(fid,'plans',id,petId:petId)),meta:null);
    }
    _only(query,<String>{});final row=await _load(fid,'plans',tail[4],petId:petId);
    if(tail.length==6){if(verb!='POST')_fail(405,'完成计划需要POST');return(data:await _completePlan(fid,petId,row,body),meta:null);}
    if(verb=='GET')return(data:await _planRead(fid,row),meta:null);await _creator(fid,row);
    if(verb=='DELETE'){
      _only(body,<String>{});await store.patch(fid,_col(fid,'plans'),tail[4],{},delete:true);
      // 历史记录保留原关联；读取时依据墓碑返回plan_id:null，避免分批清理中断。
      return(data:null,meta:null);
    }
    if(verb!='PATCH')_fail(405,'计划修改需要PATCH');final values=await _planValues(fid,body,old:row);
    if(values.isNotEmpty)await store.patch(fid,_col(fid,'plans'),tail[4],{...values,'updated_at':_stamp});return(data:await _planRead(fid,await _load(fid,'plans',tail[4],petId:petId)),meta:null);
  }
  static int? _grams(Object? value,String kind){
    if(value==null){if(kind=='weight')_fail(400,'体重记录必须填写公斤数');return null;}
    if(kind!='weight')_fail(400,'只有体重类型可填写体重');
    final text=value.toString(),match=RegExp(r'^(\d{1,4})(?:\.(\d{1,3}))?$').firstMatch(text);
    if(match==null)_fail(400,'体重必须大于0且最多三位小数');
    final grams=int.parse(match.group(1)!)*1000+int.parse((match.group(2)??'').padRight(3,'0'));
    if(grams<1||grams>1000000)_fail(400,'体重超出0.001至1000公斤范围');return grams;
  }
  static DateTime? advance(DateTime date,String unit,int interval){
    if(unit=='none')return null;if(unit=='day'||unit=='week'){final next=date.add(Duration(days:interval*(unit=='week'?7:1)));if(next.year>9999)_fail(400,'下一次日期超出支持范围');return next;}
    final month=unit=='month'?date.month+interval:date.month,year=unit=='year'?date.year+interval:date.year;
    final first=DateTime.utc(year,month,1),last=DateTime.utc(first.year,first.month+1,0).day;
    final next=DateTime.utc(first.year,first.month,date.day>last?last:date.day);if(next.year>9999)_fail(400,'下一次日期超出支持范围');return next;
  }
  Future<Json> _recordRead(String fid,Json row)async{
    final creator=await store.get(fid,'/families/$fid/members',row['created_by'] as String);
    final valid=creator!=null&&creator['family_id']==fid&&creator['user_id']==row['created_by'];
    final planId=row['plan_id'];final plan=planId is String?await store.get(fid,_col(fid,'plans'),planId):null;
    return {'id':row['id'],'family_id':fid,'pet_id':row['pet_id'],'record_type_id':row['record_type_id'],
      'type_name':row['type_name_snapshot'],'type_emoji':row['type_emoji_snapshot'],'data_kind':row['data_kind_snapshot'],
      'name':row['name'],'note':row['note'],'occurred_on':row['occurred_on'],'next_due_date':row['next_due_date'],
      'weight_kg':row['weight_grams']==null?null:((row['weight_grams'] as int)/1000).toStringAsFixed(3),
      'plan_id':plan!=null&&plan['family_id']==fid&&plan['pet_id']==row['pet_id']?planId:null,
      'scheduled_due_date':row['scheduled_due_date'],'created_by':row['created_by'],'created_at':row['created_at'],'updated_at':row['updated_at'],
      'creator_name':valid?creator?['display_name']:null,'creator_emoji':valid?creator?['avatar_emoji']:null,'creator_avatar_url':valid?creator?['avatar_url']:null,
      'attachments':[for(final d in await listAttachments(fid,row['id'] as String))_attachmentRead(d)],'attachments_pending':attachments==null&&attachmentStore==null};
  }
  Future<Json> _recordValues(String fid,Json body,{Json? old})async{
    final create=old==null,fields=<String,dynamic>{};
    _only(body,{'record_type_id','name','note','occurred_on','weight_kg','next_due_date',if(create)'follow_up'});
    if(create||body.containsKey('record_type_id')){
      final id=body['record_type_id'];if(id==null&&!create){fields['record_type_id']=null;}
      else{if(id is! String)_fail(400,'记录类型必填');final type=await _type(fid,id,active:create||id!=(old?['record_type_id']));
        fields['record_type_id']=id;if(create||id!=(old?['record_type_id']))fields.addAll({'type_name_snapshot':type['name'],'type_emoji_snapshot':type['emoji'],'data_kind_snapshot':type['data_kind']});}
    }
    if(create||body.containsKey('name'))fields['name']=_text(body['name'],80);
    if(create||body.containsKey('note'))fields['note']=_optional(body['note'],2000);
    if(create||body.containsKey('occurred_on'))fields['occurred_on']=_date(body['occurred_on']);
    if(create||body.containsKey('next_due_date'))fields['next_due_date']=body['next_due_date']==null?null:_date(body['next_due_date']);
    final kind=fields['data_kind_snapshot']??old?['data_kind_snapshot'];
    final weight=body.containsKey('weight_kg')?body['weight_kg']:old?['weight_grams']==null?null:(old!['weight_grams'] as int)/1000;
    if(create||body.containsKey('weight_kg')||fields.containsKey('data_kind_snapshot'))fields['weight_grams']=_grams(weight,kind as String);
    return fields;
  }
  Json _change(String fid,String name,String id,Json fields,{bool delete=false})=>{'space':fid,'collection':_col(fid,name),'id':id,'fields':fields,if(delete)'delete':true};
  Future<Json> _createRecord(String fid,String petId,Json body)async{
    final fields=await _recordValues(fid,body),stamp=_stamp,id=_uuid.v4(),changes=<Json>[];String? planId;
    if(body['follow_up']!=null){
      final raw=body['follow_up'];if(raw is! Map)_fail(400,'后续计划无效');final follow=Json.from(raw);_only(follow,{'plan_id','recurrence_unit','recurrence_interval','next_due_date'});
      final existing=follow['plan_id'];Json? old;if(existing!=null){if(existing is! String)_fail(400,'计划标识无效');old=await _load(fid,'plans',existing,petId:petId);await _creator(fid,old);}
      planId=existing as String? ?? _uuid.v4();
      final values=await _planValues(fid,{'record_type_id':fields['record_type_id'],'name':fields['name'],'note':fields['note'],
        'recurrence_unit':follow.containsKey('recurrence_unit')?follow['recurrence_unit']:'none','recurrence_interval':follow.containsKey('recurrence_interval')?follow['recurrence_interval']:1,
        'next_due_date':follow['next_due_date'],if(old!=null)'active':true},old:old);
      fields['next_due_date']=values['next_due_date'];changes.add(_change(fid,'plans',planId,{...values,'family_id':fid,'pet_id':petId,if(old==null)'created_by':store.deviceId,if(old==null)'created_at':stamp,'updated_at':stamp}));
    }
    changes.add(_change(fid,'records',id,{...fields,'family_id':fid,'pet_id':petId,'created_by':store.deviceId,'created_at':stamp,'updated_at':stamp,'plan_id':planId,'scheduled_due_date':null}));
    await store.batch(changes);return _recordRead(fid,await _load(fid,'records',id,petId:petId));
  }
  Future<Json> _completePlan(String fid,String petId,Json plan,Json body)async{
    _only(body,{'occurred_on','note','weight_kg','next_due_date_override','scheduled_due_date'});
    // WoApi显式带计划原到期日；稳定ID使断线重试和离线并发同一轮照护收敛。
    final scheduled=_date(body['scheduled_due_date']),id=_uuid.v5(_namespace,'pet-completion:$fid:$petId:${plan['id']}:$scheduled');
    final existing=await store.get(fid,_col(fid,'records'),id);
    if(existing!=null){if(existing['family_id']!=fid||existing['pet_id']!=petId||existing['plan_id']!=plan['id']||existing['scheduled_due_date']!=scheduled)_fail(409,'完成记录冲突');return _recordRead(fid,existing);}
    if(await store.revision(fid,_col(fid,'records'),id)>0)_fail(409,'这轮照护记录已删除，不能复用');
    if(plan['active']!=true||plan['next_due_date']!=scheduled)_fail(409,'计划日期已变更，请刷新后重试');
    final type=await _type(fid,plan['record_type_id'] as String,active:false),occurred=_date(body['occurred_on']??day(_today));
    final weight=_grams(body['weight_kg'],type['data_kind'] as String),stamp=_stamp;
    final next=body['next_due_date_override']==null?advance(DateTime.parse(occurred),plan['recurrence_unit'] as String,plan['recurrence_interval'] as int):DateTime.parse(_date(body['next_due_date_override']));
    await store.batch([
      _change(fid,'records',id,{'family_id':fid,'pet_id':petId,'record_type_id':type['id'],'type_name_snapshot':type['name'],'type_emoji_snapshot':type['emoji'],'data_kind_snapshot':type['data_kind'],
        'name':plan['name'],'note':body['note']==null?plan['note']:_optional(body['note'],2000),'occurred_on':occurred,'next_due_date':next==null?null:day(next),'weight_grams':weight,
        'plan_id':plan['id'],'scheduled_due_date':scheduled,'created_by':store.deviceId,'created_at':stamp,'updated_at':stamp}),
      _change(fid,'plans',plan['id'] as String,{'next_due_date':next==null?null:day(next),'active':next!=null,'updated_at':stamp}),
    ]);return _recordRead(fid,await _load(fid,'records',id,petId:petId));
  }
  static int _recordOrder(Json a,Json b){for(final key in ['occurred_on','created_at','id']){final c=(b[key] as String).compareTo(a[key] as String);if(c!=0)return c;}return 0;}
  Future<List<Json>> _records(String fid,String petId)async{final rows=(await _rows(fid,'records')).where((r)=>r['pet_id']==petId).toList();rows.sort(_recordOrder);return rows;}
  String _cursor(String fid,String petId,Json last)=>base64Url.encode(utf8.encode(jsonEncode({'family':fid,'pet':petId,'viewer':store.deviceId,for(final key in ['occurred_on','created_at','id'])key:last[key]})));
  Future<LocalResult> _page(String fid,String petId,Json query)async{
    _only(query,{'limit','cursor'});final raw=query['limit']??20;final limit=_int(raw is String?int.tryParse(raw):raw,1,50);final rows=await _records(fid,petId);List<Json> filtered=rows;
    if(query['cursor']!=null){Json anchor;try{final raw=query['cursor'];if(raw is! String||raw.length>2048)throw const FormatException();anchor=Json.from(jsonDecode(utf8.decode(base64Url.decode(raw))) as Map);_only(anchor,{'family','pet','viewer','occurred_on','created_at','id'});if(anchor['family']!=fid||anchor['pet']!=petId||anchor['viewer']!=store.deviceId)throw const FormatException();_date(anchor['occurred_on']);if(anchor['created_at'] is! String||DateTime.tryParse(anchor['created_at'] as String)==null||anchor['id'] is! String)throw const FormatException();_identifier(anchor['id'] as String);}catch(_){_fail(400,'分页游标无效或不属于当前家庭、宠物和成员');}filtered=rows.where((row)=>_recordOrder(row,anchor)>0).toList();}
    final page=filtered.take(limit).toList();return(data:[for(final row in page)await _recordRead(fid,row)],meta:{'total':rows.length,'cursor':filtered.length>page.length&&page.isNotEmpty?_cursor(fid,petId,page.last):null});
  }
  Future<LocalResult> _recordRequest(String verb,String fid,String petId,List<String> tail,Json body,Json query)async{
    if(tail.length==4){if(verb=='GET')return _page(fid,petId,query);_only(query,<String>{});if(verb!='POST')_fail(405,'记录列表不支持该方法');return(data:await _createRecord(fid,petId,body),meta:null);}
    _only(query,<String>{});final row=await _load(fid,'records',tail[4],petId:petId);if(verb=='GET')return(data:await _recordRead(fid,row),meta:null);await _creator(fid,row);
    if(verb=='DELETE'){_only(body,<String>{});await _deleteRecordWithAttachments(fid,petId,tail[4]);return(data:null,meta:null);}
    if(verb!='PATCH')_fail(405,'记录修改需要PATCH');final fields=await _recordValues(fid,body,old:row);if(fields.isNotEmpty)await store.patch(fid,_col(fid,'records'),tail[4],{...fields,'updated_at':_stamp});return(data:await _recordRead(fid,await _load(fid,'records',tail[4],petId:petId)),meta:null);
  }
  Json _weight(Json row)=>{'record_id':row['id'],'occurred_on':row['occurred_on'],'weight_kg':((row['weight_grams'] as int)/1000).toStringAsFixed(3)};
  Future<List<Json>> _weights(String fid,String petId)async=>(await _records(fid,petId)).where((r)=>r['data_kind_snapshot']=='weight'&&r['weight_grams']!=null).take(30).map(_weight).toList().reversed.toList();
  Future<Json> _summary(String fid,Json pet)async{
    final plans=await _plans(fid,pet['id'] as String,active:true),weights=await _weights(fid,pet['id'] as String);
    return {'pet':_petRead(pet),'next_plan':plans.isEmpty?null:await _planRead(fid,plans.first),'latest_weight':weights.isEmpty?null:weights.last};
  }
  Future<LocalResult> _request(String verb,String fid,List<String> tail,Json body,Json query)async{
    if(tail[0]=='pets')return _identity(verb,fid,tail,body,query);
    if(tail[1]=='record-types')return _types(verb,fid,tail,body,query);
    if(tail[1]=='records'){
      _only(query,<String>{});_only(body,<String>{});
      if(verb=='GET'&&tail.length==4)return(data:[for(final d in await listAttachments(fid,tail[2]))_attachmentRead(d)],meta:null);
      if(verb=='DELETE'&&tail.length==5){await _deleteAttachment(fid,tail[2],tail[4]);return(data:null,meta:null);}
      _fail(501,'本机附件请使用独立文件选择与校验入口；未上传到旧后端');
    }
    if(tail.length==2){
      _only(query,<String>{});if(verb!='GET')_fail(405,'宠物日常列表只支持GET');final pets=(await _rows(fid,'pets')).where((p)=>p['archived_at']==null).toList(),items=<Json>[];
      for(final pet in pets)items.add(await _summary(fid,pet));items.sort((a,b){final ap=(a['next_plan'] as Map?)?['next_due_date'] as String? ?? '9999-12-31',bp=(b['next_plan'] as Map?)?['next_due_date'] as String? ?? '9999-12-31';final c=ap.compareTo(bp);return c!=0?c:((a['pet'] as Map)['id'] as String).compareTo((b['pet'] as Map)['id'] as String);});return(data:items,meta:null);
    }
    final pet=await _load(fid,'pets',tail[2]);
    if(tail.length==3){
      _only(query,<String>{});if(verb!='GET')_fail(405,'宠物面板只支持GET');final plans=await _plans(fid,tail[2],active:true),weights=await _weights(fid,tail[2]),records=await _page(fid,tail[2],{'limit':20});
      return(data:{'pet':_petRead(pet),'today_plans':[for(final p in plans)if((p['next_due_date'] as String).compareTo(day(_today))<=0)await _planRead(fid,p)],'upcoming_plans':[for(final p in plans)if((p['next_due_date'] as String).compareTo(day(_today))>0)await _planRead(fid,p)],'latest_weight':weights.isEmpty?null:weights.last,'weight_trend':weights,'records':records.data,'records_cursor':records.meta?['cursor']},meta:null);
    }
    if(tail[3]=='plans')return _planRequest(verb,fid,tail[2],tail,body,query);
    if(tail[3]=='records')return _recordRequest(verb,fid,tail[2],tail,body,query);
    _only(query,<String>{});if(verb!='GET')_fail(405,'体重曲线只支持GET');return(data:await _weights(fid,tail[2]),meta:null);
  }
  /// 只验证当前有来源的操作；previous必须是同步管道实际前序状态，不能补造历史来源。
  static void validateRecordSync(Json fields,{required String familyId,required String id,required String actor,
      Json? previous,required bool owner,bool deletion=false}){
    Never bad()=>throw const FormatException('宠物记录字段、作者或不可变绑定无效');
    bool identifier(Object? value)=>value is String&&_id.hasMatch(value)&&_id.firstMatch(value)!.end==value.length;
    bool text(Object? value,int max,{bool nullable=false})=>value==null?nullable:value is String&&value.trim().isNotEmpty&&value.runes.length<=max;
    bool date(Object? value,{bool nullable=false}){
      if(value==null)return nullable;if(value is! String||!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value))return false;
      final parsed=DateTime.tryParse(value);return parsed!=null&&parsed.year>=1&&parsed.year<=9999&&day(parsed)==value;
    }
    bool stamp(Object? value){if(value is! String||value.length>64)return false;final parsed=DateTime.tryParse(value);return parsed!=null&&parsed.isUtc;}
    if(!identifier(familyId)||!identifier(id)||!identifier(actor))bad();
    if(previous!=null){
      if(previous['family_id']!=familyId||!identifier(previous['created_by'])||!identifier(previous['pet_id'])||
          previous['created_by']!=actor&&!owner)bad();
    }else if(deletion){bad();}
    if(deletion)return;
    final allowed=syncFields['plugins/pet/records']!;
    if(fields.length!=allowed.length||!allowed.every(fields.containsKey)||fields.keys.any((k)=>!allowed.contains(k))||
        fields['family_id']!=familyId||!identifier(fields['pet_id'])||!identifier(fields['created_by'])||
        fields['record_type_id']!=null&&!identifier(fields['record_type_id'])||fields['plan_id']!=null&&!identifier(fields['plan_id'])||
        !text(fields['type_name_snapshot'],32)||!text(fields['type_emoji_snapshot'],16)||!{'general','weight'}.contains(fields['data_kind_snapshot'])||
        !text(fields['name'],80)||fields['note']!=null&&(fields['note'] is! String||(fields['note'] as String).runes.length>2000)||
        !date(fields['occurred_on'])||!date(fields['next_due_date'],nullable:true)||!date(fields['scheduled_due_date'],nullable:true)||
        !stamp(fields['created_at'])||!stamp(fields['updated_at']))bad();
    final grams=fields['weight_grams'];
    if(fields['data_kind_snapshot']=='weight'?(grams is! int||grams<1||grams>1000000):grams!=null)bad();
    if(previous==null){if(fields['created_by']!=actor)bad();}
    else{for(final key in ['family_id','pet_id','created_by','created_at','plan_id','scheduled_due_date']){if(fields[key]!=previous[key])bad();}}
    if(fields['scheduled_due_date']!=null){
      if(fields['plan_id']==null||id!=_uuid.v5(_namespace,'pet-completion:$familyId:${fields['pet_id']}:${fields['plan_id']}:${fields['scheduled_due_date']}'))bad();
    }
  }
  // 普通附件只保存独立副本；媒体原件、旧URI及恢复资料库都不参与此入口。
  static const maxAttachments=10;
  Future<OrdinaryAttachmentStore> _fileStore()async{
    if(attachments!=null)return attachments!;final load=attachmentStore;
    if(load==null)throw ApiException('FEATURE_UNAVAILABLE','本机附件存储尚未就绪',statusCode:501);return load();
  }
  static AttachmentBinding _binding(AttachmentDescriptor d)=>AttachmentBinding(familyId:d.familyId,plugin:'pet',parentId:d.parentId,authorDeviceId:d.authorDeviceId);
  static Json _attachmentRead(AttachmentDescriptor d)=>{'id':d.id,'original_filename':d.displayName,'content_type':d.contentType,'size_bytes':d.size,'url':''};
  Future<Json> _attachmentParent(String fid,String recordId)async{
    await _member(fid);final record=await _load(fid,'records',recordId);
    // 旧附件API只要求record存在；宠物归档不删除历史附件，也不授予新成员权限。
    await _load(fid,'pets',record['pet_id'] as String,archived:true);return record;
  }
  AttachmentDescriptor _descriptor(Json row,String fid,String recordId){
    final d=AttachmentDescriptor.fromJson(row);
    if(d.familyId!=fid||d.plugin!='pet'||d.parentId!=recordId||!{'pet_image_copy','pet_file_copy'}.contains(d.purpose))_fail(409,'附件绑定无效');return d;
  }
  Future<List<AttachmentDescriptor>> listAttachments(String fid,String recordId)async{
    await _attachmentParent(fid,recordId);final rows=await _rows(fid,'attachments');
    final found=[for(final row in rows)if(row['parent_id']==recordId)_descriptor(row,fid,recordId)];
    found.sort((a,b){final time=a.createdAt.compareTo(b.createdAt);return time!=0?time:a.id.compareTo(b.id);});return List.unmodifiable(found);
  }
  Future<AttachmentSelectionMetadata?> pickAttachment(String fid,{required String purpose})async{
    await _member(fid);if(!{'pet_image_copy','pet_file_copy'}.contains(purpose))_fail(400,'附件用途无效');return (await _fileStore()).pick(purpose:purpose);
  }
  Future<Json?> _txRow(DatabaseExecutor tx,String fid,String name,String id)async{
    final rows=await tx.query('documents',where:'space=? AND collection=? AND id=?',whereArgs:[fid,_col(fid,name),id]);
    if(rows.isEmpty||rows.single['deleted']==1)return null;return {...Json.from(jsonDecode(rows.single['data'] as String) as Map),'id':id};
  }
  Future<Json> _txParent(DatabaseExecutor tx,String fid,String recordId,{required bool write})async{
    final memberRows=await tx.query('documents',where:'space=? AND collection=? AND id=? AND deleted=0',whereArgs:[fid,'/families/$fid/members',store.deviceId]);
    final member=memberRows.isEmpty?null:Json.from(jsonDecode(memberRows.single['data'] as String) as Map);
    if(member==null||member['status']!='active'||member['family_id']!=fid||member['user_id']!=store.deviceId||!{'owner','member'}.contains(member['role']))_fail(403,'本机没有有效家庭成员身份');
    final record=await _txRow(tx,fid,'records',recordId);
    if(record==null||record['family_id']!=fid)_fail(404,'宠物记录不存在或已删除');
    final pet=await _txRow(tx,fid,'pets',record['pet_id'] as String);if(pet==null||pet['family_id']!=fid)_fail(404,'宠物资料不存在');
    if(write&&member['role']!='owner'&&record['created_by']!=store.deviceId)_fail(403,'只能修改自己记录的附件');return record;
  }
  Future<List<AttachmentDescriptor>> _txAttachments(DatabaseExecutor tx,String fid,String recordId)async{
    final rows=await tx.query('documents',where:'space=? AND collection=? AND deleted=0',whereArgs:[fid,_col(fid,'attachments')]);
    return [for(final raw in rows)if((jsonDecode(raw['data'] as String) as Map)['parent_id']==recordId)
      _descriptor({...Json.from(jsonDecode(raw['data'] as String) as Map),'id':raw['id']},fid,recordId)];
  }
  static String _selectionId(String fid,String recordId,String token)=>'a_${_uuid.v5(_namespace,'pet-attachment:$fid:$recordId:$token').replaceAll('-','')}';
  Future<AttachmentDescriptor> addAttachment(String fid,String recordId,AttachmentSelectionMetadata selection)=>_serial(fid,()async{
    final parent=await _attachmentParent(fid,recordId);await _creator(fid,parent);
    if(!{'pet_image_copy','pet_file_copy'}.contains(selection.purpose))_fail(400,'附件用途无效');
    final id=_selectionId(fid,recordId,selection.token);
    final old=await store.get(fid,_col(fid,'attachments'),id);
    if(old==null&&await store.revision(fid,_col(fid,'attachments'),id)>0)_fail(409,'附件已删除，不能重试复活');
    if(old==null&&(await listAttachments(fid,recordId)).length>=maxAttachments)_fail(400,'每条记录最多10个附件');
    final binding=AttachmentBinding(familyId:fid,plugin:'pet',parentId:recordId,authorDeviceId:store.deviceId);
    final asset=await (await _fileStore()).importSelection(selectionToken:selection.token,purpose:selection.purpose,binding:binding,attachmentId:id);
    final descriptor=asset.descriptor;
    if(descriptor.id!=id||descriptor.familyId!=fid||descriptor.plugin!='pet'||descriptor.parentId!=recordId||descriptor.authorDeviceId!=store.deviceId)_fail(409,'附件副本绑定不一致');
    try{
      await store.batchComputed((tx)async{
        await _txParent(tx,fid,recordId,write:true);
        final existing=await tx.query('documents',where:'space=? AND collection=? AND id=?',whereArgs:[fid,_col(fid,'attachments'),id]);
        if(existing.isNotEmpty){
          if(existing.single['deleted']==1)_fail(409,'附件已删除，不能重试复活');
          final expected=Json.from(descriptor.toJson())..remove('id');
          if(LocalStore.canonical(Json.from(jsonDecode(existing.single['data'] as String) as Map))!=LocalStore.canonical(expected))_fail(409,'附件描述不可变');return <Json>[];
        }
        if((await _txAttachments(tx,fid,recordId)).length>=maxAttachments)_fail(400,'每条记录最多10个附件');
        final fields=Json.from(descriptor.toJson())..remove('id');return [_change(fid,'attachments',id,fields)];
      });
      return descriptor;
    }catch(_){
      // 事务故障保留同一已校验副本供稳定ID重试；无业务描述时绝不能被同步/备份导出。
      // 父已删除或撤权后只清本机未发布副本，不删除用户源文件。
      if(await store.get(fid,_col(fid,'attachments'),id)==null){
        var authorized=true;try{await _creator(fid,await _attachmentParent(fid,recordId));}catch(_){authorized=false;}
        if(!authorized){try{await (await _fileStore()).deleteLocal(binding,id);}catch(_){}}
      }rethrow;
    }
  });
  /// 仅当前本机权限；peer来源仍必须由同步adapter单独验证，不能据此恢复旧身份。
  Future<AttachmentDescriptor> authorizeAttachment(String fid,String recordId,String id,{bool write=false})async{
    final parent=await _attachmentParent(fid,recordId);if(write)await _creator(fid,parent);
    return _descriptor(await _load(fid,'attachments',id),fid,recordId);
  }
  Future<void> releaseAttachmentSelection(String token,{String? familyId,String? recordId})async{
    final files=await _fileStore();
    try{if(familyId!=null&&recordId!=null){
      _identifier(familyId);_identifier(recordId);final id=_selectionId(familyId,recordId,token);
      if(await store.get(familyId,_col(familyId,'attachments'),id)==null){
        final binding=AttachmentBinding(familyId:familyId,plugin:'pet',parentId:recordId,authorDeviceId:store.deviceId);
        if(await files.get(binding,id)!=null)await files.deleteLocal(binding,id);
      }
    }}finally{await files.releaseSelection(token);}
  }
  Future<File?> attachmentFile(String fid,String recordId,String id)async{
    final descriptor=await authorizeAttachment(fid,recordId,id);
    final files=await _fileStore();final asset=await files.get(_binding(descriptor),id);
    if(asset==null||!asset.available){await authorizeAttachment(fid,recordId,id);return null;}
    if(!asset.descriptor.same(descriptor))_fail(409,'附件本机副本与业务描述不一致');
    final file=await files.verifiedFile(_binding(descriptor),id);
    await authorizeAttachment(fid,recordId,id);return file;
  }
  Future<void> deleteAttachment(String fid,String recordId,String id)=>_serial(fid,()=>_deleteAttachment(fid,recordId,id));
  Future<void> _deleteAttachment(String fid,String recordId,String id)async{
    AttachmentDescriptor? deleted;
    await store.batchComputed((tx)async{await _txParent(tx,fid,recordId,write:true);final row=await _txRow(tx,fid,'attachments',id);
      if(row==null)_fail(404,'附件不存在或已删除');deleted=_descriptor(row,fid,recordId);return [_change(fid,'attachments',id,{},delete:true)];});
    if((attachments!=null||attachmentStore!=null)&&deleted!=null){try{await (await _fileStore()).deleteLocal(_binding(deleted!),id);}catch(_){/*墓碑已提交，缺件/暂存清理由文件层报告。*/}}
  }
  Future<void> _deleteRecordWithAttachments(String fid,String petId,String recordId)async{
    final deleted=<AttachmentDescriptor>[];
    await store.batchComputed((tx)async{final record=await _txParent(tx,fid,recordId,write:true);
      final pet=await _txRow(tx,fid,'pets',petId);if(record['pet_id']!=petId||pet==null||pet['archived_at']!=null)_fail(404,'宠物已归档或记录不属于该宠物');
      deleted.addAll(await _txAttachments(tx,fid,recordId));return [_change(fid,'records',recordId,{},delete:true),for(final d in deleted)_change(fid,'attachments',d.id,{},delete:true)];});
    if(attachments!=null||attachmentStore!=null){for(final d in deleted){try{await (await _fileStore()).deleteLocal(_binding(d),d.id);}catch(_){}}}
  }
  /// 仅生成可重试本地通知请求；不会伪称系统通知已投递，也不代替用户完成计划。
  Future<int> requestDueReminders(String fid)async{await _member(fid);return _serial(fid,()async{
    final installed=await store.list(fid,'/families/$fid/installed');if(!installed.any((row)=>row['plugin_id']=='pet'&&row['enabled']==true))return 0;
    final recipients=[for(final m in await store.list(fid,'/families/$fid/members'))if(m['family_id']==fid&&m['status']=='active'&&m['user_id']==m['id'])m['id']];var count=0;
    for(final plan in await _rows(fid,'plans')){
      final due=plan['next_due_date'];if(plan['active']!=true||due is! String||due.compareTo(day(_today))>0)continue;
      final pet=await store.get(fid,_col(fid,'pets'),plan['pet_id'] as String);if(pet==null||pet['archived_at']!=null||pet['family_id']!=fid)continue;
      final id=_uuid.v5(_namespace,'pet-due:$fid:${plan['id']}:$due');if(await store.revision(fid,'/families/$fid/notifications',id)>0)continue;
      await store.patch(fid,'/families/$fid/notifications',id,{'type':'pet_care_due','title':'${pet['name']}的照护提醒','body':'${plan['name']} 已到计划日期','icon_emoji':pet['emoji'],'created_by':store.deviceId,'created_at':_stamp,'read_by':<String>[],'status':'pending_local_delivery','recipient_ids':recipients,'source_plugin':'pet','source_id':plan['id'],'source_occurrence':due});count++;
    }return count;
  });}
}
