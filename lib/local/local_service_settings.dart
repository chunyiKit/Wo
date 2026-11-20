import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../services/external_services.dart';
import 'local_store.dart';
import 'transport/native_local.dart';

enum LocalWeatherAuthentication { apiKey, bearerJwt }
class LocalServiceSettingsException implements Exception {
  const LocalServiceSettingsException(this.code);final String code;
  @override String toString()=>'本机服务配置不可用 ($code)';
}
class LocalServiceView {
  const LocalServiceView({this.enabled=false,this.endpoint='',this.hasCredentialReference=false,
    this.remoteFamilyId='',this.model='',this.retentionNotice='',this.protocol=WeatherProtocol.currentV1,
    this.authentication=LocalWeatherAuthentication.apiKey});
  final bool enabled,hasCredentialReference;final String endpoint,remoteFamilyId,model,retentionNotice;
  final WeatherProtocol protocol;final LocalWeatherAuthentication authentication;
}
class LocalServicesView {
  const LocalServicesView(this.movie,this.weather,this.image,{this.pendingCredentialCleanup=false});
  final LocalServiceView movie,weather,image;final bool pendingCredentialCleanup;
}

/// 仅meta private保存ref/非秘密设置，绝不写documents、operations或普通旧AI settings。
/// 构造/readSettings不定位、不读取凭据正文、不发HTTP；调用方不得备份或同步此private键。
class LocalServiceSettings {
  LocalServiceSettings({required this.store,required this.crypto,http.Client? client,
      Future<AuthorizedLocation?> Function()? locateWithPermission})
    :_client=client??http.Client(),_ownsClient=client==null,_locate=locateWithPermission??locateDeviceForWeather;
  final LocalStore store;final LocalCrypto crypto;final http.Client _client;final bool _ownsClient;
  final Future<AuthorizedLocation?> Function() _locate;
  static const privateKey='local-external-services-v1';
  Future<void> _queue=Future<void>.value();bool _closed=false;
  Future<T> _serial<T>(Future<T> Function() action){
    if(_closed)return Future<T>.error(const LocalServiceSettingsException('closed'));
    final work=_queue.then<T>((_)=>action());_queue=work.then<void>((_) {},onError:(Object _,StackTrace __){});return work;
  }
  static bool _full(RegExp p,String value){final m=p.firstMatch(value);return m!=null&&m.end==value.length;}
  static bool _ref(String value,[String? service]) {
    if(!_full(RegExp(r'^wo\.services\.(movie|weather|image)\.[a-f0-9]{32}$'),value))return false;
    return service==null||value.startsWith('wo.services.$service.');
  }

  Future<Map<String,dynamic>> _read({String? onlyService})async{
    final raw=await store.privateValue(privateKey);if(raw==null)return {'v':1,'retired_refs':<String>[]};
    if(raw is! Map||raw['v']!=1||raw.keys.any((k)=>!{'v','movie','weather','image','retired_refs'}.contains(k)))throw const LocalServiceSettingsException('invalid_metadata');
    final root=Map<String,dynamic>.from(raw);final retired=root['retired_refs'];
    if(retired is! List||retired.length>64||retired.any((r)=>r is! String||!_ref(r)))throw const LocalServiceSettingsException('invalid_metadata');
    for(final name in ['movie','weather','image']){
      if(onlyService!=null&&onlyService!=name)continue;
      final value=root[name];if(value==null)continue;if(value is! Map)throw const LocalServiceSettingsException('invalid_metadata');
      final m=Map<String,dynamic>.from(value);final keys={'enabled','endpoint','credential_ref',if(name=='movie')'remote_family',if(name=='weather')...'protocol auth'.split(' '),if(name=='image')...'model retention_notice'.split(' ')};
      if(m.keys.any((k)=>!keys.contains(k))||m['enabled'] is! bool||m['endpoint'] is! String||
        (m['credential_ref']!=null&&(m['credential_ref'] is! String||!_ref(m['credential_ref'] as String,name))))throw const LocalServiceSettingsException('invalid_metadata');
      _validateMetadata(name,m);root[name]=m;
    }
    final active={for(final name in ['movie','weather','image'])if(root[name] is Map&&(root[name] as Map)['credential_ref'] is String)(root[name] as Map)['credential_ref'] as String};
    if(retired.toSet().length!=retired.length||retired.any(active.contains))throw const LocalServiceSettingsException('invalid_metadata');
    return root;
  }
  static Uri _endpoint(String input){
    final uri=Uri.tryParse(input);
    if(uri==null||uri.scheme!='https'||uri.host.isEmpty||uri.userInfo.isNotEmpty||uri.hasQuery||uri.hasFragment)throw const LocalServiceSettingsException('invalid_endpoint');
    return uri.replace(path:uri.path.replaceFirst(RegExp(r'/+$'),''));
  }
  static void _validateMetadata(String name,Map<String,dynamic> m){
    final endpoint=_endpoint(m['endpoint'] as String);
    if(name=='movie'){
      if(m['remote_family'] is! String)throw const LocalServiceSettingsException('invalid_metadata');
      MovieBackendConfig(baseUrl:endpoint,remoteFamilyId:m['remote_family'] as String,bearerToken:'synthetic-validation-only');
    }else if(name=='weather'){
      if(!WeatherProtocol.values.any((v)=>v.name==m['protocol'])||!LocalWeatherAuthentication.values.any((v)=>v.name==m['auth']))throw const LocalServiceSettingsException('invalid_metadata');
      WeatherServiceConfig(baseUrl:endpoint,protocol:WeatherProtocol.values.firstWhere((v)=>v.name==m['protocol']),apiKey:'synthetic-validation-only');
    }else{
      if(m['model'] is! String||(m['model'] as String).trim().isEmpty||(m['model'] as String).length>200||
         m['retention_notice'] is! String||(m['retention_notice'] as String).length>8000||
         (m['enabled']==true&&(m['retention_notice'] as String).trim().isEmpty))throw const LocalServiceSettingsException('model_policy_required');
      ImageModelConfig(baseUrl:endpoint,apiKey:'synthetic-validation-only',model:m['model'] as String,retentionNotice:m['retention_notice'] as String);
    }
  }
  Future<LocalServicesView> readSettings()=>_serial(()async{
    final root=await _read();LocalServiceView view(String name){final m=root[name];if(m==null)return const LocalServiceView();final j=m as Map<String,dynamic>;
      return LocalServiceView(enabled:j['enabled'] as bool,endpoint:j['endpoint'] as String,hasCredentialReference:j['credential_ref']!=null,
        remoteFamilyId:j['remote_family'] as String? ??'',model:j['model'] as String? ??'',retentionNotice:j['retention_notice'] as String? ??'',
        protocol:name=='weather'?WeatherProtocol.values.firstWhere((v)=>v.name==j['protocol']):WeatherProtocol.currentV1,
        authentication:name=='weather'?LocalWeatherAuthentication.values.firstWhere((v)=>v.name==j['auth']):LocalWeatherAuthentication.apiKey);}
    return LocalServicesView(view('movie'),view('weather'),view('image'),pendingCredentialCleanup:(root['retired_refs'] as List).isNotEmpty);
  });
  Future<void> saveMovie({required Uri baseUrl,required String remoteFamilyId,required bool enabled,String? bearerToken})=>_save('movie',
    {'enabled':enabled,'endpoint':baseUrl.toString(),'remote_family':remoteFamilyId},bearerToken);
  Future<void> saveWeather({required Uri baseUrl,required bool enabled,WeatherProtocol protocol=WeatherProtocol.currentV1,
      LocalWeatherAuthentication authentication=LocalWeatherAuthentication.apiKey,String? credential})=>_save('weather',
    {'enabled':enabled,'endpoint':baseUrl.toString(),'protocol':protocol.name,'auth':authentication.name},credential);
  Future<void> saveImage({required Uri baseUrl,required String model,required String retentionNotice,required bool enabled,String? apiKey})=>_save('image',
    {'enabled':enabled,'endpoint':baseUrl.toString(),'model':model,'retention_notice':retentionNotice},apiKey);
  Future<void> _save(String name,Map<String,dynamic> next,String? credential)=>_serial(()async{
    next['endpoint']=_endpoint(next['endpoint'] as String).toString();_validateMetadata(name,next);
    final root=await _read(),old=root[name] as Map<String,dynamic>?;
    final oldRef=old?['credential_ref'] as String?;String? newRef;
    final changed=old!=null&&(old['endpoint']!=next['endpoint']||(name=='weather'&&old['auth']!=next['auth']));
    if(credential!=null){
      if(credential.isEmpty||credential.length>4096||credential.runes.any((r)=>r<33||r>126))throw const LocalServiceSettingsException('invalid_credential');
      final random=await crypto.random(16);if(random.length!=16)throw const LocalServiceSettingsException('invalid_random');
      newRef='wo.services.$name.${random.map((n)=>n.toRadixString(16).padLeft(2,'0')).join()}';
    }else if(!changed){newRef=oldRef;}
    if(next['enabled']==true&&newRef==null)throw LocalServiceSettingsException(changed?'credential_reentry_required':'credential_required');
    final retired=List<String>.from(root['retired_refs'] as List);
    if(oldRef!=null&&oldRef!=newRef)retired.add(oldRef);
    if(retired.length>64)throw const LocalServiceSettingsException('cleanup_required');
    if(newRef!=null)next['credential_ref']=newRef;
    if(credential!=null){final bytes=Uint8List.fromList(utf8.encode(credential));try{await crypto.putSecret(newRef!,bytes);}finally{bytes.fillRange(0,bytes.length,0);}}
    try{root[name]=next;root['retired_refs']=retired;await store.setPrivate(privateKey,root);}
    catch(_){if(credential!=null&&newRef!=null)await crypto.deleteSecret(newRef);throw const LocalServiceSettingsException('settings_save_failed');}
    await _cleanup(root);
  });
  Future<void> remove(String name)=>_serial(()async{
    if(!{'movie','weather','image'}.contains(name))throw const LocalServiceSettingsException('invalid_service');
    final root=await _read(),old=root.remove(name) as Map<String,dynamic>?;final retired=List<String>.from(root['retired_refs'] as List);
    final ref=old?['credential_ref'] as String?;if(ref!=null)retired.add(ref);if(retired.length>64)throw const LocalServiceSettingsException('cleanup_required');root['retired_refs']=retired;
    await store.setPrivate(privateKey,root);await _cleanup(root);
  });
  Future<void> cleanupRetiredCredentials()=>_serial(()async{await _cleanup(await _read());});
  Future<void> _cleanup(Map<String,dynamic> root)async{
    final remaining=<String>[];for(final ref in List<String>.from(root['retired_refs'] as List)){
      try{await crypto.deleteSecret(ref);}catch(_){remaining.add(ref);}
    }
    root['retired_refs']=remaining;await store.setPrivate(privateKey,root);
    if(remaining.isNotEmpty)throw const LocalServiceSettingsException('credential_cleanup_failed');
  }
  Future<String?> _credential(Map<String,dynamic> m,String name)async{
    final ref=m['credential_ref'];if(ref is! String||!_ref(ref,name))return null;
    final bytes=await crypto.getSecret(ref);if(bytes==null)return null;
    try{if(bytes.isEmpty||bytes.length>4096)return null;final text=utf8.decode(bytes,allowMalformed:false);if(text.runes.any((r)=>r<33||r>126))return null;return text;}
    finally{bytes.fillRange(0,bytes.length,0);}
  }
  Future<MovieBackendConfig?> loadMovieConfig()=>_serial(()async{
    final m=(await _read(onlyService:'movie'))['movie'] as Map<String,dynamic>?;if(m==null||m['enabled']!=true)return null;
    final token=await _credential(m,'movie');if(token==null)return null;
    return MovieBackendConfig(baseUrl:_endpoint(m['endpoint'] as String),remoteFamilyId:m['remote_family'] as String,bearerToken:token);
  });
  Future<WeatherServiceConfig?> loadWeatherConfig()=>_serial(()async{
    final m=(await _read(onlyService:'weather'))['weather'] as Map<String,dynamic>?;if(m==null||m['enabled']!=true)return null;
    final credential=await _credential(m,'weather');if(credential==null)return null;
    final jwt=m['auth']==LocalWeatherAuthentication.bearerJwt.name;
    return WeatherServiceConfig(baseUrl:_endpoint(m['endpoint'] as String),protocol:WeatherProtocol.values.firstWhere((v)=>v.name==m['protocol']),
      apiKey:jwt?'':credential,bearerToken:jwt?credential:'');
  });
  Future<ImageModelConfig?> loadImageConfig()=>_serial(()async{
    final m=(await _read(onlyService:'image'))['image'] as Map<String,dynamic>?;if(m==null||m['enabled']!=true)return null;
    final key=await _credential(m,'image');if(key==null)return null;
    return ImageModelConfig(baseUrl:_endpoint(m['endpoint'] as String),apiKey:key,model:m['model'] as String,retentionNotice:m['retention_notice'] as String);
  });
  MovieCatalogueClient movieClient()=>MovieCatalogueClient(loadConfig:loadMovieConfig,client:_client);
  WeatherClient weatherClient()=>WeatherClient(loadConfig:loadWeatherConfig,locateWithPermission:_locate,client:_client);
  ConfiguredImageClient imageClient()=>ConfiguredImageClient(loadConfig:loadImageConfig,client:_client);
  void close(){_closed=true;if(_ownsClient)_client.close();}
}

/// 只能由明确“查询天气”操作调用。不读旧家庭坐标、不缓存/记录坐标、不异常回退旧位置。
Future<AuthorizedLocation?> locateDeviceForWeather()async{
  try{
    if(!await Geolocator.isLocationServiceEnabled())return null;
    var permission=await Geolocator.checkPermission();
    if(permission==LocationPermission.denied)permission=await Geolocator.requestPermission();
    if(permission!=LocationPermission.whileInUse&&permission!=LocationPermission.always)return null;
    final p=await Geolocator.getCurrentPosition(locationSettings:const LocationSettings(accuracy:LocationAccuracy.low,timeLimit:Duration(seconds:12)));
    return AuthorizedLocation(p.latitude,p.longitude);
  }catch(_){return null;}
}
