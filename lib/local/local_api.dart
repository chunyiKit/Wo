import 'package:uuid/uuid.dart';
import '../data/api_client.dart';
import 'local_backend.dart';
import 'local_store.dart';
import 'plugin_catalog.dart';
import 'plugins/recipe_expiry.dart';

/// 本地业务边界；未实现的路由明确失败，绝不静默退回远端写入。
class LocalApi implements LocalBackend {
  LocalApi(this.store, {DateTime Function()? now}) : now = now ?? DateTime.now;
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
  Future<List<String>> get families async => ((await store.privateValue('families') as List?) ?? []).cast<String>();
  static Never _fail(String code,String message,[int status=400]) => throw ApiException(code,message,statusCode:status);

  Future<void> initialize() async {
    if (await store.privateValue(_profile) == null) {
      await store.setPrivate(_profile, {'id':store.deviceId,'username':'local-${store.deviceId.substring(0,8)}',
        'display_name':'我','avatar_emoji':'👤','avatar_url':null,'avatar_version':0,'level':1,'created_at':_stamp});
    }
    if ((await families).isEmpty) await _createFamily({'name':'我的家','emoji':'🏡'});
    familyId = await store.privateValue('current-family') as String? ?? (await families).first;
    final today=now().toIso8601String().substring(0,10);
    final days=((await store.privateValue('active-days') as List?)??[]).cast<String>().toSet()..add(today);
    await store.setPrivate('active-days',days.toList()..sort());
  }

  Future<Json> _createFamily(Json body) async {
    final name='${body['name']??''}'.trim();
    if (name.isEmpty || name.length>80) _fail('VALIDATION_ERROR','家庭名称须为1至80个字');
    final fid=const Uuid().v4(), user=await self;
    final known=[...await families,fid];
    await store.batch([
      {'space':fid,'collection':_col(fid,'family'),'id':fid,'fields':{'name':name,'slogan':body['slogan'],'emoji':body['emoji']??'🏡','background_url':null,'created_at':_stamp}},
      {'space':fid,'collection':_col(fid,'members'),'id':store.deviceId,'fields':{'user_id':store.deviceId,'family_id':fid,'role':'owner','display_name':user['display_name'],'avatar_emoji':user['avatar_emoji'],'avatar_url':user['avatar_url'],'status':'active','joined_at':_stamp}},
    ],privateUpdates:{'families':known,'current-family':fid});
    familyId=fid;return _family(fid);
  }
  Future<void> _joined(String fid) async {
    if (!(await families).contains(fid)) _fail('FORBIDDEN','本机尚未加入这个家庭',403);
    final member=await store.get(fid,_col(fid,'members'),store.deviceId);
    if (member==null || member['status']!='active') _fail('FORBIDDEN','当前设备没有有效家庭成员权限',403);
  }
  Future<Json> _family(String fid) async {
    final row=await store.get(fid,_col(fid,'family'),fid);
    if(row==null) _fail('NOT_FOUND','家庭不存在',404);
    final member=await store.get(fid,_col(fid,'members'),store.deviceId);
    return {...row!,'member_count':(await store.list(fid,_col(fid,'members'))).where((m)=>m['status']=='active').length,
      'pet_count':(await store.list(fid,_col(fid,'pets'))).length,'my_role':member?['role']??'member','my_unread_count':0};
  }
  Future<Json> _installed(String fid,Json row) async {
    final plugin=localPluginCatalog.where((p)=>p['id']==row['plugin_id']).firstOrNull;
    if(plugin==null) _fail('NOT_FOUND','本机目录中不存在此插件',404);
    return {...row,'family_id':fid,'plugin':plugin,'preview':{'primary':'本机记录','secondary':'记录功能分模块接入中','color_token':plugin!['color_token'],'emoji':plugin['emoji']}};
  }
  Future<List<Json>> _installedList(String fid) async => [for(final row in await store.list(fid,_col(fid,'installed'))) await _installed(fid,row)];
  Future<Json> _bootstrap() async => {'user':await self,'current_family':familyId==null?null:await _family(familyId!),
    'families':[for(final id in await families)await _family(id)],'installed_plugins':familyId==null?[]:await _installedList(familyId!),'unread_count':0};

  @override
  Future<LocalResult> request(String method,String path,{Object? body,Map<String,dynamic>? query,
    List<(List<int>,String)>? files,Map<String,String>? fields}) async {
    if(files!=null && files.isNotEmpty) _fail('LOCAL_MODULE_PENDING','本机媒体模块尚未接入，文件未上传到任何服务',501);
    final uri=Uri.parse(path);final parts=uri.pathSegments;final data=body is Map?Map<String,dynamic>.from(body):<String,dynamic>{};
    final q={...uri.queryParameters,...?query};
    dynamic result;
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
    else if(path=='/notifications' && method=='GET') result=<Json>[];
    else if(path=='/me/notification-preferences' && method=='GET') result=await store.privateValue('notification-preferences')??{'push_enabled':false,'sources':[]};
    else if(path=='/me/notification-preferences' && method=='PATCH') {
      _fail('LOCAL_MODULE_PENDING','本机系统提醒尚未接入，未修改通知开关',501);
    }
    else if(parts.length>=2 && parts[0]=='families') {
      final fid=parts[1];await _joined(fid);
      if(parts.length==2 && method=='GET') result=await _family(fid);
      else if(parts.length==2 && method=='PATCH') {
        if(data.keys.any((k)=>!['name','emoji','slogan'].contains(k))) _fail('VALIDATION_ERROR','未知家庭字段');
        if(data['name']!=null && '${data['name']}'.trim().isEmpty) _fail('VALIDATION_ERROR','名称不能为空');
        await store.patch(fid,_col(fid,'family'),fid,data);result=await _family(fid);
      }
      else if(parts.length==3 && parts[2]=='switch' && method=='POST') {
        familyId=fid;await store.setPrivate('current-family',fid);result=await _family(fid);
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
        final handled=await RecipeExpiryRoutes(store,now:now).request(method,fid,parts.sublist(3),body:data,query:q);
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
