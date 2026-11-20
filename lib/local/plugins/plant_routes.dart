import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../data/api_client.dart';
import '../../services/external_services.dart';
import '../local_backend.dart';
import '../local_store.dart';

/// 植物事实本地；currentWeather 必须由根注入一次前台权限查询，不写默认环境。
class PlantRoutes {
  PlantRoutes(this.store,{this.currentWeather,DateTime Function()? now}):_now=now??DateTime.now;
  final LocalStore store;
  final Future<Json> Function()? currentWeather;
  final DateTime Function() _now;
  static const _uuid=Uuid();
  static const _defaults=['室内','南阳台','朝南窗','朝北窗','室外'];
  static const syncFields=<String,Set<String>>{
    'plugins/plant/plants':{'family_id','name','emoji','species','placement','water_interval_days','fert_interval_days','next_water_due','next_fert_due','created_at'},
    'plugins/plant/logs':{'family_id','plant_id','created_at','note','env_snapshot','ai_status','ai_assessment','ai_advice','ai_suggested_water_days','ai_suggested_fert_days'},
    'plugins/plant/settings':{'placements','updated_at'},
    'notifications':{'type','title','body','icon_emoji','created_by','created_at','read_by','status','recipient_ids','source_plugin','source_id','source_occurrence'},
  };
  static const _weatherFields={'available','reason','location_label','latitude','longitude','temp_c','feels_like_c','condition','icon','humidity_pct','precip_mm','pressure_hpa','visibility_km','cloud_pct','dew_point_c','wind_dir','wind_scale','wind_speed_kmh','wind_deg','uv_index','observed_at'};
  static final _id=RegExp(r'^[A-Za-z0-9_-]{1,100}$');
  static final _queues=Expando<Map<String,Future<void>>>();
  String _col(String fid,String name)=>'/families/$fid/plugins/plant/$name';
  String _manualKey(String fid)=>'plant-manual-environment:$fid';
  String get _stamp=>_now().toUtc().toIso8601String();
  DateTime get _today{final d=_now();return DateTime.utc(d.year,d.month,d.day);}
  static String _day(DateTime d)=>[d.year.toString().padLeft(4,'0'),d.month.toString().padLeft(2,'0'),d.day.toString().padLeft(2,'0')].join('-');
  static Never _fail(int status,String text)=>throw ApiException(switch(status){403=>'FORBIDDEN',404=>'NOT_FOUND',405=>'METHOD_NOT_ALLOWED',501=>'FEATURE_UNAVAILABLE',_=>'VALIDATION_ERROR'},text,statusCode:status);
  static void _only(Json body,Set<String> fields){if(body.keys.any((key)=>!fields.contains(key)))_fail(400,'包含未知或只读字段');}
  static String _text(Object? value,int max){if(value is! String||value.trim().isEmpty||value.runes.length>max)_fail(400,'文本为空或过长');return value.trim();}
  static String? _optional(Object? value,int max){if(value==null)return null;if(value is! String||value.runes.length>max)_fail(400,'文本无效或过长');return value.trim().isEmpty?null:value.trim();}
  static int? _interval(Object? value){if(value==null)return null;if(value is! int||value<1||value>365)_fail(400,'养护周期须为1至365天或留空');return value;}
  Future<void> _member(String fid)async{
    if(!_id.hasMatch(fid))_fail(400,'家庭标识无效');final m=await store.get(fid,'/families/$fid/members',store.deviceId);
    if(m==null||m['status']!='active'||m['family_id']!=fid||m['user_id']!=store.deviceId)_fail(403,'本机没有有效家庭成员身份');
  }
  Future<T> _serial<T>(String fid,Future<T> Function() action){final queues=_queues[store]??=<String,Future<void>>{},result=Completer<T>();queues[fid]=(queues[fid]??Future<void>.value()).then((_)async{try{result.complete(await action());}catch(e,s){result.completeError(e,s);}});return result.future;}
  Future<Json> _plant(String fid,String id)async{
    if(!_id.hasMatch(id))_fail(400,'植物标识无效');final row=await store.get(fid,_col(fid,'plants'),id);if(row==null||row['family_id']!=fid)_fail(404,'植物不存在');return row;
  }
  Future<Json> _log(String fid,String plantId,String id)async{
    if(!_id.hasMatch(id))_fail(400,'记录标识无效');final row=await store.get(fid,_col(fid,'logs'),id);if(row==null||row['family_id']!=fid||row['plant_id']!=plantId)_fail(404,'养护记录不存在');return row;
  }
  Future<List<Json>> _plants(String fid)async=>[for(final row in await store.list(fid,_col(fid,'plants')))if(row['family_id']==fid)row];
  Future<List<Json>> _logs(String fid,String plantId)async{
    final rows=[for(final row in await store.list(fid,_col(fid,'logs')))if(row['family_id']==fid&&row['plant_id']==plantId)row];
    rows.sort((a,b){final c=DateTime.parse(b['created_at'] as String).compareTo(DateTime.parse(a['created_at'] as String));return c!=0?c:(a['id'] as String).compareTo(b['id'] as String);});return rows;
  }
  Future<LocalResult?> request(String method,String fid,List<String> tail,{Json body=const{},Json query=const{}})async{
    if(tail.length<2||tail[0]!='plant')return null;
    final known=tail.length==2&&['plants','settings','weather'].contains(tail[1])||tail[1]=='plants'&&(
      tail.length==3||tail.length==4&&['cover','logs'].contains(tail[3])||tail.length==5&&tail[3]=='logs'||tail.length==6&&tail[3]=='logs'&&['photo','reanalyze','adopt'].contains(tail[5])||tail.length==7&&tail[3]=='logs'&&tail[5]=='photos');
    if(!known)return null;await _member(fid);_only(query,<String>{});final verb=method.toUpperCase();
    if(verb=='GET')return _request(verb,fid,tail,body);return _serial(fid,()=>_request(verb,fid,tail,body));
  }
  Json _plantRead(Json row)=>{'id':row['id'],'family_id':row['family_id'],'name':row['name'],'emoji':row['emoji'],'species':row['species'],'placement':row['placement'],
    'water_interval_days':row['water_interval_days'],'fert_interval_days':row['fert_interval_days'],'next_water_due':row['next_water_due'],'next_fert_due':row['next_fert_due'],'created_at':row['created_at'],'cover_url':null,'cover_pending':true};
  Json _logRead(Json row)=>{'id':row['id'],'family_id':row['family_id'],'plant_id':row['plant_id'],'created_at':row['created_at'],'note':row['note'],'env_snapshot':row['env_snapshot'],
    'ai_status':row['ai_status'],'ai_assessment':row['ai_assessment'],'ai_advice':row['ai_advice'],'ai_suggested_water_days':row['ai_suggested_water_days'],'ai_suggested_fert_days':row['ai_suggested_fert_days'],
    'photo_url':null,'photo_urls':<String>[],'media_pending':true,'analysis_enabled':false};
  Json _values(Json body,{Json? old}){
    _only(body,{'name','emoji','species','placement','water_interval_days','fert_interval_days'});final create=old==null,values=<String,dynamic>{};
    if(create||body.containsKey('name'))values['name']=_text(body['name'],40);
    if(create||body.containsKey('emoji'))values['emoji']=_text(body.containsKey('emoji')?body['emoji']:'🌿',16);
    if(create||body.containsKey('species'))values['species']=_optional(body['species'],60);
    if(create||body.containsKey('placement'))values['placement']=_text(body.containsKey('placement')?body['placement']:'室内',24);
    for(final kind in ['water','fert']){final key='${kind}_interval_days';if(create||body.containsKey(key)){
      final interval=_interval(body[key]);values[key]=interval;
      if(create||interval!=old![key])values['next_${kind}_due']=interval==null?null:_day(_today.add(Duration(days:interval)));
    }}return values;
  }
  Future<LocalResult> _request(String verb,String fid,List<String> tail,Json body)async{
    if(tail[1]=='weather'){
      if(verb!='GET')_fail(405,'当前天气只支持GET');_only(body,<String>{});
      // 旧页面会在初始化时 GET；不能把这次读取当作定位授权动作。
      return(data:{'available':false,'reason':'explicit_action_required'},meta:{'persisted':false});
    }
    if(tail[1]=='settings')return _settings(verb,fid,body);
    if(tail.length==2){
      if(verb=='GET'){final rows=await _plants(fid);rows.sort((a,b)=>DateTime.parse(b['created_at'] as String).compareTo(DateTime.parse(a['created_at'] as String)));return(data:rows.map(_plantRead).toList(),meta:null);}
      if(verb!='POST')_fail(405,'植物列表不支持该方法');final fields=_values(body),id=_uuid.v4();await store.patch(fid,_col(fid,'plants'),id,{...fields,'family_id':fid,'created_at':_stamp});return(data:_plantRead(await _plant(fid,id)),meta:null);
    }
    if(tail.length==3&&verb=='DELETE'){
      _only(body,<String>{});final id=tail[2];if(!_id.hasMatch(id))_fail(400,'植物标识无效');
      final old=await store.get(fid,_col(fid,'plants'),id);
      if(old==null&&await store.revision(fid,_col(fid,'plants'),id)==0||old!=null&&old['family_id']!=fid)_fail(404,'植物不存在');
      if(old!=null)await store.patch(fid,_col(fid,'plants'),id,{},delete:true);
      final logs=await _logs(fid,id);for(var start=0;start<logs.length;start+=256){await store.batch([for(final log in logs.skip(start).take(256)){'space':fid,'collection':_col(fid,'logs'),'id':log['id'],'fields':<String,dynamic>{},'delete':true}]);}
      return(data:null,meta:null);
    }
    final plant=await _plant(fid,tail[2]),plantId=tail[2];
    if(tail.length==3){
      if(verb=='GET')return(data:_plantRead(plant),meta:null);
      if(!['PUT','PATCH'].contains(verb))_fail(405,'植物不支持该方法');final fields=_values(body,old:plant);
      if(fields.isNotEmpty)await store.patch(fid,_col(fid,'plants'),plantId,fields);return(data:_plantRead(await _plant(fid,plantId)),meta:null);
    }
    if(tail[3]=='cover')_fail(501,'植物照片文件服务尚未接入，未保存或上传照片');
    if(tail.length==4){
      if(verb=='GET')return(data:[for(final row in await _logs(fid,plantId))_logRead(row)],meta:null);
      if(verb!='POST')_fail(405,'养护记录不支持该方法');
      if(body.keys.any((key)=>['photos','media_ids','files'].contains(key)))_fail(501,'植物照片独立媒体绑定尚未接入，可保留文件并单独保存文字记录');
      _only(body,{'note'});final note=_text(body['note'],500),id=_uuid.v4();
      await store.patch(fid,_col(fid,'logs'),id,{'family_id':fid,'plant_id':plantId,'created_at':_stamp,'note':note,'env_snapshot':{'placement':plant['placement']},
        'ai_status':'none','ai_assessment':null,'ai_advice':null,'ai_suggested_water_days':null,'ai_suggested_fert_days':null});
      return(data:_logRead(await _log(fid,plantId,id)),meta:null);
    }
    final log=await _log(fid,plantId,tail[4]);
    if(tail.length==5){
      if(verb=='GET')return(data:_logRead(log),meta:null);
      if(verb!='DELETE')_fail(405,'养护记录不支持该方法');_only(body,<String>{});await store.patch(fid,_col(fid,'logs'),tail[4],{},delete:true);return(data:null,meta:null);
    }
    if(tail[5]=='adopt'){
      if(verb!='POST')_fail(405,'采纳建议需要POST');_only(body,{'water','fert'});
      for(final key in ['water','fert']){if(body.containsKey(key)&&body[key] is! bool)_fail(400,'采纳开关无效');}
      final values=<String,dynamic>{};
      for(final kind in ['water','fert']){final value=log['ai_suggested_${kind}_days'];if(body[kind]!=false&&value!=null)values['${kind}_interval_days']=_interval(value);}
      if(values.isEmpty)_fail(400,'没有可采纳的本地建议值；可手动设置周期');
      await store.patch(fid,_col(fid,'plants'),plantId,_values(values,old:plant));return(data:_plantRead(await _plant(fid,plantId)),meta:null);
    }
    if(tail[5]=='reanalyze')_fail(501,'本地日志未启用远程植物分析，文字与周期仍可编辑');
    _fail(501,'植物照片文件服务尚未接入，未返回原始照片网络地址');
  }
  /// 仅供明确前台按钮调用；HTTP GET/初始化/后台均不自动进入此方法。
  Future<Json> weatherForUserAction(String fid)async{
    await _member(fid);final load=currentWeather;
    if(load==null)return {'available':false,'reason':'当前天气读取未配置，本机植物仍可使用'};
    try{
      final snapshot=await load();if(snapshot['available'] is! bool)return {'available':false,'reason':'天气响应无效'};
      return {for(final key in _weatherFields)if(snapshot.containsKey(key))key:snapshot[key]};
    }catch(e){return {'available':false,'reason':e is ExternalServiceException&&e.failure==ServiceFailure.locationDenied?'定位未授权':'天气暂不可用，默认环境保持不变'};}
  }
  Future<LocalResult> _settings(String verb,String fid,Json body)async{
    if(verb=='GET'){_only(body,<String>{});return(data:await settings(fid),meta:null);}
    if(verb!='PUT')_fail(405,'默认环境仅支持GET/PUT');_only(body,{'latitude','longitude','location_label','placements'});
    final old=await store.privateValue(_manualKey(fid));final manual=old is Map?Json.from(old):<String,dynamic>{};
    for(final key in ['latitude','longitude']){if(body.containsKey(key)){final value=body[key];final limit=key=='latitude'?90:180;if(value!=null&&(value is! num||!value.isFinite||value.abs()>limit))_fail(400,'手编默认坐标无效');manual[key]=value;}}
    if((manual['latitude']==null)!=(manual['longitude']==null))_fail(400,'默认位置需要完整坐标或同时清除');
    if(body.containsKey('location_label'))manual['location_label']=_optional(body['location_label'],60);
    List<String>? placements;
    if(body.containsKey('placements')){final raw=body['placements'];if(raw is! List||raw.any((p)=>p is! String))_fail(400,'摆放标签必须是文本列表');placements=<String>[];
      for(final text in raw){final label=String.fromCharCodes((text as String).trim().runes.take(24));if(label.isNotEmpty&&!placements.contains(label))placements.add(label);if(placements.length==30)break;}}
    final hasManual=body.keys.any((key)=>key!='placements');
    if(placements!=null||hasManual)await store.batch([
      if(placements!=null){'space':fid,'collection':_col(fid,'settings'),'id':'environment','fields':{'placements':placements,'updated_at':_stamp}},
    ],privateUpdates:{if(hasManual)_manualKey(fid):manual});
    return(data:await settings(fid),meta:null);
  }
  Future<Json> settings(String fid)async{
    await _member(fid);final row=await store.get(fid,_col(fid,'settings'),'environment'),old=await store.privateValue(_manualKey(fid));
    final manual=old is Map?Json.from(old):<String,dynamic>{};final presets=row?['placements'];
    return {'latitude':manual['latitude'],'longitude':manual['longitude'],'location_label':manual['location_label'],'placements':presets is List&&presets.isNotEmpty?presets:List<String>.of(_defaults)};
  }
  Future<Json> preview(String fid)async{
    await _member(fid);final rows=await _plants(fid);if(rows.isEmpty)return {'primary':'还没有植物','secondary':'添加一株','color_token':'plant','emoji':'🌿'};
    ({String due,String kind,Json plant})? best;
    for(final plant in rows){for(final kind in ['water','fert']){final due=plant['next_${kind}_due'];if(due is String&&(best==null||due.compareTo(best!.due)<0))best=(due:due,kind:kind,plant:plant);}}
    if(best==null)return {'primary':'${rows.length} 株植物','secondary':'都照料好啦','color_token':'plant','emoji':'🌿'};
    return {'primary':'该给『${best!.plant['name']}』${best!.kind=='water'?'浇水':'施肥'}','secondary':'共 ${rows.length} 株','color_token':'plant','emoji':best!.plant['emoji']};
  }
  Future<int> requestDueReminders(String fid)=>_serial(fid,()async{
    await _member(fid);final members=await store.list(fid,'/families/$fid/members');final recipients=[for(final m in members)if(m['family_id']==fid&&m['status']=='active'&&m['id']==m['user_id'])m['user_id'] as String];var touched=0;
    for(final plant in await _plants(fid)){
      final changes=<String,dynamic>{},notifications=<Json>[];
      for(final kind in ['water','fert']){
        final interval=plant['${kind}_interval_days'],raw=plant['next_${kind}_due'];if(interval is! int||interval<1||raw is! String)continue;
        final d=DateTime.parse(raw),due=DateTime.utc(d.year,d.month,d.day);if(due.isAfter(_today))continue;
        final steps=_today.difference(due).inDays~/interval+1;changes['next_${kind}_due']=_day(due.add(Duration(days:steps*interval)));
        final id=_uuid.v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8','plant:$fid:${plant['id']}:$kind:$raw');
        if(await store.revision(fid,'/families/$fid/notifications',id)==0)notifications.add({'space':fid,'collection':'/families/$fid/notifications','id':id,'fields':{
          'type':kind=='water'?'plant_water_due':'plant_fert_due','title':'该给「${plant['name']}」${kind=='water'?'浇水':'施肥'}了','body':'请查看本机养护安排','icon_emoji':plant['emoji'],
          'created_by':store.deviceId,'created_at':_stamp,'read_by':<String>[],'status':'pending_local_delivery','recipient_ids':recipients,'source_plugin':'plant','source_id':plant['id'],'source_occurrence':raw,
        }});
      }
      if(changes.isNotEmpty){await store.batch([{'space':fid,'collection':_col(fid,'plants'),'id':plant['id'],'fields':changes},...notifications]);touched++;}
    }return touched;
  });
}
