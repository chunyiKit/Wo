import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../data/api_client.dart';
import 'local_backend.dart';
import 'local_store.dart';
import 'plugin_catalog.dart';
import 'plugins/recipe_expiry.dart';
import 'plugins/memory_routes.dart';
import 'plugins/stock_accounting.dart';
import 'plugins/calendar_routes.dart';
import 'plugins/chat_routes.dart';
import 'plugins/plant_routes.dart';
import 'plugins/retirement_subscription.dart';
import 'plugins/pet_routes.dart';
import 'plugins/travel_routes.dart';
import 'plugins/movie_chore_anniversary.dart';
import '../services/external_services.dart';

/// 本地业务边界；未实现的路由明确失败，绝不静默退回远端写入。
class LocalApi implements LocalBackend {
  LocalApi(this.store, {DateTime Function()? now,this.memories,this.catalogue,this.travels,this.onMutated}) : now = now ?? DateTime.now;
  final MemoryRoutes? memories;
  final MovieCatalogueClient? catalogue;
  final TravelRoutes? travels;
  final void Function()? onMutated;
  final LocalStore store;
  final DateTime Function() now;
  String? familyId;
  @override
  String get mediaBaseUrl => '';
  @override
  Map<String,String> get mediaHeaders => const {};
  String get _stamp => now().toUtc().toIso8601String();
  String get _profile => 'self-profile';
  String _col(String fid,String name) => '/families/$fid/$name';
  Future<Json> get self async => Map<String,dynamic>.from(await store.privateValue(_profile) as Map);
  Future<List<String>> get _knownFamilies async => ((await store.privateValue('families') as List?) ?? []).cast<String>();
  Future<List<String>> get families async {
    final result=<String>[];
    for(final fid in await _knownFamilies){
      final member=await store.get(fid,_col(fid,'members'),store.deviceId);
      if(member!=null&&member['status']=='active'&&member['family_id']==fid&&member['user_id']==store.deviceId&&['owner','member'].contains(member['role'])&&await store.get(fid,_col(fid,'family'),fid)!=null)result.add(fid);
    }return result;
  }
  Future<void> _selectActiveFamily()async{
    final active=await families,preferred=await store.privateValue('current-family') as String?;
    familyId=active.contains(preferred)?preferred:active.firstOrNull;
    if(preferred!=familyId)await store.setPrivate('current-family',familyId);
  }
  static Never _fail(String code,String message,[int status=400]) => throw ApiException(code,message,statusCode:status);

  Future<void> initialize() async {
    if (await store.privateValue(_profile) == null) {
      await store.setPrivate(_profile, {'id':store.deviceId,'username':'local-${store.deviceId.substring(0,8)}',
        'display_name':'我','avatar_emoji':'👤','avatar_url':null,'avatar_version':0,'level':1,'created_at':_stamp});
    }
    if ((await _knownFamilies).isEmpty) await _createFamily({'name':'我的家','emoji':'🏡'});
    await _selectActiveFamily();
    final today=now().toIso8601String().substring(0,10);
    final days=((await store.privateValue('active-days') as List?)??[]).cast<String>().toSet()..add(today);
    await store.setPrivate('active-days',days.toList()..sort());
  }

  Future<Json> _createFamily(Json body) async {
    final name='${body['name']??''}'.trim();
    if (name.isEmpty || name.length>80) _fail('VALIDATION_ERROR','家庭名称须为1至80个字');
    final fid=const Uuid().v4(), user=await self;
    final known=[...await _knownFamilies,fid];
    await store.batch([
      {'space':fid,'collection':_col(fid,'family'),'id':fid,'fields':{'name':name,'slogan':body['slogan'],'emoji':body['emoji']??'🏡','background_url':null,'created_at':_stamp}},
      {'space':fid,'collection':_col(fid,'members'),'id':store.deviceId,'fields':{'user_id':store.deviceId,'family_id':fid,'role':'owner','display_name':user['display_name'],'avatar_emoji':user['avatar_emoji'],'avatar_url':user['avatar_url'],'status':'active','joined_at':_stamp}},
    ],privateUpdates:{'families':known,'current-family':fid});
    familyId=fid;return _family(fid);
  }
  Future<void> _joined(String fid) async {
    if (!(await families).contains(fid)) _fail('FORBIDDEN','本机尚未加入这个家庭',403);
    final member=await store.get(fid,_col(fid,'members'),store.deviceId);
    if (member==null || member['status']!='active'||member['family_id']!=fid||member['user_id']!=store.deviceId||!['owner','member'].contains(member['role'])) _fail('FORBIDDEN','当前设备没有有效家庭成员权限',403);
  }
  Future<Json> _family(String fid) async {
    await _joined(fid);
    final row=await store.get(fid,_col(fid,'family'),fid);
    if(row==null) _fail('NOT_FOUND','家庭不存在',404);
    final member=await store.get(fid,_col(fid,'members'),store.deviceId);
    return {...row!,'member_count':(await store.list(fid,_col(fid,'members'))).where((m)=>m['status']=='active'&&m['family_id']==fid&&m['user_id']==m['id']).length,
      'pet_count':(await store.list(fid,_col(fid,'pets'))).where((row)=>row['family_id']==fid&&row['archived_at']==null).length,'my_role':member?['role']??'member','my_unread_count':(await _notifications()).where((row)=>row['family_id']==fid&&row['is_read']!=true).length};
  }
  Future<Json> _installed(String fid,Json row) async {
    await _joined(fid);
    final plugin=localPluginCatalog.where((p)=>p['id']==row['plugin_id']).firstOrNull;
    if(plugin==null) _fail('NOT_FOUND','本机目录中不存在此插件',404);
    return {...row,'family_id':fid,'plugin':plugin,'preview':await _preview(fid,row,plugin!)};
  }
  /// 每次以当前本机身份重算，不将受限标题/计数写入共享卡片文档。
  Future<Json> _preview(String fid,Json install,Json plugin) async {
    final id=plugin['id'];var primary='本机记录',secondary='打开查看本机资料';
    if(id=='memory' && memories!=null){
      final rows=await memories!.visibleSnapshot(fid);
      primary=rows.isEmpty?'留下一段回忆':'${rows.length} 段可见回忆';
      secondary=rows.isEmpty?'照片与视频原件保留在各自设备':'${rows.first['title']}';
    }else if(id=='accounting'){
      final result=await StockAccountingRoutes(store,now:now).request('GET',fid,['accounting','summary']);
      final totals=Map<String,dynamic>.from(result!.data as Map);
      primary='本月支出 ¥${totals['month_total']}';secondary=totals['budget']==null?'尚未设置每月预算':'预算剩余 ¥${totals['remaining']}';
    }else if(id=='stock'){
      final result=await StockAccountingRoutes(store,now:now).request('GET',fid,['stock','items']);
      final rows=(result!.data as List).cast<Map>();
      primary='${rows.length} 项囤货';secondary=rows.any((row)=>row['quantity_conflict']==true)?'存在待盘点的数量冲突':'${rows.where((row)=>row['is_low']==true).length} 项低量';
    }else if(id=='retirement'){
      final result=await RetirementSubscriptionRoutes(store,now:now).request('GET',fid,['retirement','dashboard']);
      final summary=Map<String,dynamic>.from(result!.data as Map);primary='净资产 ¥${summary['net_worth']}';
      secondary=summary['ledger_conflict']==true?'存在待核对的账期或余额':'本机前台处理账期';
    }else if(id=='subscription'){
      final result=await RetirementSubscriptionRoutes(store,now:now).request('GET',fid,['subscription','subscriptions']);
      final rows=(result!.data as List).cast<Map>();primary='${rows.where((r)=>r['active']==true).length} 项订阅';
      secondary=rows.any((r)=>r['billing_conflict']==true)?'存在待核对的到期账目':'${rows.where((r)=>r['active']==true&&(r['days_until'] as int)<0).length} 项已到期';
    }else if(id=='travel'&&travels!=null){
      final rows=await travels!.snapshot(fid);primary='${rows.length} 段旅行';secondary=rows.isEmpty?'原照与记录保留在本机':'${rows.first['city_name']}';
    }else if(id=='pet'){
      final rows=(await store.list(fid,_col(fid,'pets'))).where((r)=>r['family_id']==fid&&r['archived_at']==null).toList();primary='${rows.length} 位宠物';secondary='照护与体重记录保存在本机';
    }else if(id=='plant'){
      return {...await PlantRoutes(store,now:now).preview(fid),'color_token':plugin['color_token'],'emoji':plugin['emoji']};
    }else if(id=='calendar'){
      return {...await CalendarRoutes(store,now:now).preview(fid),'color_token':plugin['color_token'],'emoji':plugin['emoji']};
    }else if(id=='anniversary'){
      return {...await MovieChoreAnniversaryRoutes(store,now:now).anniversaryPreview(fid,config:Map<String,dynamic>.from(install['config'] as Map? ?? const {})),
        'color_token':plugin['color_token'],'emoji':plugin['emoji']};
    }else{
      final source=switch(id){'recipe'=>'recipe/recipes','expiry'=>'expiry/items','movie'=>'movie/movies','chore'=>'chore/chores','stock'=>'stock/items',_=>null};
      if(source!=null){
        final rows=await store.list(fid,_col(fid,'plugins/$source'));
        primary='${rows.length} 条本机记录';
        if(id=='chore')secondary='${rows.where((r)=>r['done']!=true).length} 项待完成';
        if(id=='movie')secondary='${rows.where((r)=>r['watched']!=true).length} 部待观看';
      }
    }
    return {'primary':primary,'secondary':secondary,'color_token':plugin['color_token'],'emoji':plugin['emoji']};
  }
  Future<List<Json>> _notifications() async {
    final result=<Json>[];
    for(final fid in await families){
      try{await _joined(fid);}on ApiException{continue;}
      for(final row in await store.list(fid,_col(fid,'notifications'))){
        final recipients=row['recipient_ids'];
        if(recipients is! List || recipients.any((id)=>id is! String || id.isEmpty) || !recipients.contains(store.deviceId))continue;
        if(await store.privateValue('notification-hidden:$fid:${row['id']}')==true)continue;
        final marker=await store.privateValue('notification-read:$fid:${row['id']}');
        final readAt=_notificationReadAt(marker);
        result.add({...row,'family_id':fid,'is_read':marker==true||readAt!=null,'read_at':readAt,'extras':{'delivery_status':row['status']??'pending_local_delivery'}});
      }
    }
    result.sort((a,b)=>'${b['created_at']}'.compareTo('${a['created_at']}'));return result;
  }
  // 旧版true保留已读，但没有真实时间时不伪造read_at。
  String? _notificationReadAt(Object? marker)=>marker is String&&DateTime.tryParse(marker)!=null?marker:null;
  Future<int> _markNotificationsRead(List<Json> rows)=>store.db.transaction((tx)async{
    final stamp=_stamp;var marked=0;
    for(final row in rows){
      final key='private:notification-read:${row['family_id']}:${row['id']}';
      final existing=await tx.query('meta',columns:['value'],where:'key=?',whereArgs:[key]);
      final marker=existing.isEmpty?null:jsonDecode(existing.single['value'] as String);
      if(marker==true||_notificationReadAt(marker)!=null)continue;
      await tx.rawInsert('INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)',[key,jsonEncode(stamp)]);
      marked++;
    }
    return marked;
  });
  Future<void> _notificationAction(String id,{required bool hide})async{
    final rows=(await _notifications()).where((row)=>row['id']==id).toList();
    if(rows.length!=1)_fail('NOT_FOUND','通知不存在或标识有冲突',404);
    if(hide){await store.setPrivate('notification-hidden:${rows.single['family_id']}:$id',true);}
    else{await _markNotificationsRead(rows);}
  }
  Future<List<Json>> _installedList(String fid) async => [for(final row in await store.list(fid,_col(fid,'installed'))) await _installed(fid,row)];
  Future<Json> _bootstrap() async => {'user':await self,'current_family':familyId==null?null:await _family(familyId!),
    'families':[for(final id in await families)await _family(id)],'installed_plugins':familyId==null?[]:await _installedList(familyId!),'unread_count':(await _notifications()).where((r)=>r['is_read']!=true).length};

  @override
  Future<LocalResult> request(String method,String path,{Object? body,Map<String,dynamic>? query,
    List<(List<int>,String)>? files,Map<String,String>? fields}) async {
    final result=await _request(method,path,body:body,query:query,files:files,fields:fields);
    if(method.toUpperCase()!='GET')onMutated?.call();
    return result;
  }
  Future<LocalResult> _request(String method,String path,{Object? body,Map<String,dynamic>? query,
    List<(List<int>,String)>? files,Map<String,String>? fields}) async {
    if(files!=null && files.isNotEmpty) _fail('LOCAL_MODULE_PENDING','本地媒体不使用旧上传接口，文件未上传到任何服务',501);
    final uri=Uri.parse(path);final parts=uri.pathSegments;final data=body is Map?Map<String,dynamic>.from(body):<String,dynamic>{};
    final q={...uri.queryParameters,...?query};
    dynamic result;
    if(['/me/bootstrap','/me','/me/families'].contains(uri.path))await _selectActiveFamily();
    if(method=='GET' && path=='/me/bootstrap') result=await _bootstrap();
    else if(path=='/me' && method=='GET') result={'user':await self,'current_family':familyId==null?null:await _family(familyId!),
      'stats':{'families_joined':(await families).length,'plugins_used':familyId==null?0:(await _installedList(familyId!)).length,'days_active':((await store.privateValue('active-days') as List?)??[]).length}};
    else if(path=='/me' && method=='PATCH') {
      if(data.keys.any((k)=>!['display_name','avatar_emoji'].contains(k))) _fail('VALIDATION_ERROR','未知个人资料字段');
      final profile={...await self,...data};await store.setPrivate(_profile,profile);
      for(final fid in await families) {
        await store.patch(fid,_col(fid,'members'),store.deviceId,{'display_name':profile['display_name'],'avatar_emoji':profile['avatar_emoji']});
      }
      result=profile;
    }
    else if(path=='/plugins' && method=='GET') result=localPluginCatalog;
    else if(parts.length==2 && parts[0]=='plugins' && method=='GET') {
      result=localPluginCatalog.where((p)=>p['id']==parts[1]).firstOrNull;
      if(result==null) _fail('NOT_FOUND','插件不存在或尚未发布',404);
    }
    else if(path=='/me/families' && method=='GET') result=[for(final id in await families)await _family(id)];
    else if(path=='/families' && method=='POST') result=await _createFamily(data);
    else if(path=='/notifications' && method=='GET') {
      final limit=int.tryParse('${q['limit']??50}');if(limit==null||limit<1||limit>500)_fail('VALIDATION_ERROR','通知条数无效');
      result=(await _notifications()).take(limit).toList();
    }
    else if(path=='/notifications/read-all' && method=='POST'){
      final rows=await _notifications();result={'marked':await _markNotificationsRead(rows)};
    }
    else if(parts.length==3&&parts[0]=='notifications'&&parts[2]=='read'&&method=='PATCH'){await _notificationAction(parts[1],hide:false);result=null;}
    else if(parts.length==2&&parts[0]=='notifications'&&method=='DELETE'){await _notificationAction(parts[1],hide:true);result=null;}
    else if(path=='/me/notification-preferences' && method=='GET') result=await store.privateValue('notification-preferences')??{'push_enabled':false,'sources':[]};
    else if(path=='/me/notification-preferences' && method=='PATCH') {
      _fail('LOCAL_MODULE_PENDING','本机系统提醒尚未接入，未修改通知开关',501);
    }
    else if(parts.length>=2 && parts[0]=='families') {
      final fid=parts[1];await _joined(fid);
      if(parts.length==2 && method=='GET') result=await _family(fid);
      else if(parts.length==2 && method=='PATCH') {
        final member=await store.get(fid,_col(fid,'members'),store.deviceId);if(member?['role']!='owner')_fail('FORBIDDEN','仅家庭创建者可修改家庭资料',403);
        if(data.keys.any((k)=>!['name','emoji','slogan'].contains(k))) _fail('VALIDATION_ERROR','未知家庭字段');
        if(data['name']!=null && '${data['name']}'.trim().isEmpty) _fail('VALIDATION_ERROR','名称不能为空');
        await store.patch(fid,_col(fid,'family'),fid,data);result=await _family(fid);
      }
      else if(parts.length==3 && parts[2]=='switch' && method=='POST') {
        familyId=fid;await store.setPrivate('current-family',fid);result=await _family(fid);
      }
      else if(parts.length>=3&&parts[2]=='pets'){
        final handled=await PetRoutes(store,now:now).request(method,fid,parts.sublist(2),body:data,query:q);
        if(handled==null)_fail('LOCAL_MODULE_PENDING','本地宠物入口尚未支持该操作',501);return handled!;
      }
      else if(parts.length==3 && parts[2]=='members' && method=='GET') result=await store.list(fid,_col(fid,'members'));
      else if(parts.length==3 && parts[2]=='plugins' && method=='GET') result=await _installedList(fid);
      else if(parts.length==3 && parts[2]=='plugins' && method=='POST') {
        final plugin=localPluginCatalog.where((p)=>p['id']==data['plugin_id']).firstOrNull;
        if(plugin==null) _fail('NOT_FOUND','插件不存在或尚未发布',404);
        final installed=await store.list(fid,_col(fid,'installed'));
        final existing=installed.where((p)=>p['plugin_id']==plugin!['id']).firstOrNull;
        if(existing!=null && plugin!['multi_instance']!=true) result=await _installed(fid,existing);
        else {
          final id=const Uuid().v4();
          final maxBottom=installed.fold<int>(0,(end,item){final l=item['layout'] as Map;final next=(l['row'] as int)+(l['ch'] as int);return next>end?next:end;});
          await store.patch(fid,_col(fid,'installed'),id,{'plugin_id':plugin!['id'],'enabled':true,'config':<String,dynamic>{},
            'layout':{'col':0,'row':maxBottom,...Map<String,dynamic>.from(plugin['default_layout'] as Map)}});
          result=await _installed(fid,(await store.get(fid,_col(fid,'installed'),id))!);
        }
      }
      else if(parts.length==4 && parts[2]=='plugins' && ['PATCH','DELETE'].contains(method)) {
        final id=parts[3],row=await store.get(fid,_col(fid,'installed'),parts[3]);
        if(row==null) _fail('NOT_FOUND','卡片不存在',404);
        if(method=='DELETE') {await store.patch(fid,_col(fid,'installed'),id,{},delete:true);result=null;}
        else {
          if(data.keys.any((k)=>!['config','enabled'].contains(k))) _fail('VALIDATION_ERROR','未知卡片字段');
          await store.patch(fid,_col(fid,'installed'),id,data);result=await _installed(fid,(await store.get(fid,_col(fid,'installed'),id))!);
        }
      }
      else if(parts.length==3 && parts[2]=='layout' && method=='PUT') {
        final rows=await store.list(fid,_col(fid,'installed'));
        if(data['items'] is! List) _fail('VALIDATION_ERROR','布局必须为列表');
        final items=(data['items'] as List).map((x)=>Map<String,dynamic>.from(x as Map)).toList();
        if(items.length!=rows.length || items.map((x)=>x['install_id']).toSet().length!=rows.length ||
            !items.every((x)=>rows.any((row)=>row['id']==x['install_id']))) _fail('VALIDATION_ERROR','布局必须恰好覆盖全部卡片');
        final occupied=<String>{};
        for(final item in items) {
          for(final key in ['col','row','cw','ch']) {if(item[key] is! int) _fail('VALIDATION_ERROR','布局坐标必须为整数');}
          final col=item['col'] as int,row=item['row'] as int,cw=item['cw'] as int,ch=item['ch'] as int;
          if(col<0 || row<0 || cw<1 || cw>4 || col+cw>4 || ch<1 || ch>8 || row>10000) _fail('VALIDATION_ERROR','布局越界');
          for(var y=row;y<row+ch;y++) {for(var x=col;x<col+cw;x++) {if(!occupied.add('$x:$y')) _fail('VALIDATION_ERROR','卡片布局重叠');}}
        }
        await store.batch([for(final item in items){'space':fid,'collection':_col(fid,'installed'),'id':item['install_id'],
          'fields':{'layout':{for(final key in ['col','row','cw','ch'])key:item[key]}}}]);result=null;
      }
      else if(parts.length>=4 && parts[2]=='plugins') {
        final tail=parts.sublist(3);
        final handled=await memories?.request(method,fid,tail,body:data,query:q)
          ??await travels?.request(method,fid,tail,body:data,query:q)
          ??await PetRoutes(store,now:now).request(method,fid,tail,body:data,query:q)
          ??await StockAccountingRoutes(store,now:now).request(method,fid,tail,body:data,query:q)
          ??await MovieChoreAnniversaryRoutes(store,catalogue:catalogue,now:now).request(method,fid,tail,body:data,query:q)
          ??await ChatRoutes(store,now:now).request(method,fid,tail,body:data,query:q)
          ??await CalendarRoutes(store,now:now).request(method,fid,tail,body:data,query:q)
          ??await PlantRoutes(store,now:now).request(method,fid,tail,body:data,query:q)
          ??await RetirementSubscriptionRoutes(store,now:now).request(method,fid,tail,body:data,query:q)
          ??await RecipeExpiryRoutes(store,now:now).request(method,fid,tail,body:data,query:q);
        if(handled==null) _fail('LOCAL_MODULE_PENDING','此本地功能正在按模块接入，未向旧后端发送请求',501);
        return handled!;
      }
      else _fail('LOCAL_MODULE_PENDING','此本地功能尚未接入，未向旧后端发送请求',501);
    }
    else if(parts.isNotEmpty && (parts[0]=='auth' || parts[0]=='devices')) _fail('LOCAL_IDENTITY','本机身份不使用旧云账号或远程设备注册',409);
    else _fail('LOCAL_MODULE_PENDING','此本地路由尚未接入，未向旧后端发送请求',501);
    return (data:result,meta:null);
  }
}
