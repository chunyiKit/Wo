import 'dart:async';
import 'package:flutter/material.dart';
import '../../local/local_service_settings.dart';
import '../../services/external_services.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_card.dart';

/// 只编辑本机可选服务。初始化不调用凭据正文、定位、电影或图片模型接口。
class LocalServicesPage extends StatefulWidget {
  const LocalServicesPage({super.key,required this.settings});final LocalServiceSettings settings;
  @override State<LocalServicesPage> createState()=>_LocalServicesPageState();
}
class _LocalServicesPageState extends State<LocalServicesPage> {
  final _movieUrl=TextEditingController(),_movieFamily=TextEditingController(),_movieToken=TextEditingController();
  final _weatherUrl=TextEditingController(),_weatherCredential=TextEditingController();
  final _imageUrl=TextEditingController(),_imageModel=TextEditingController(),_imageKey=TextEditingController(),_retention=TextEditingController();
  bool _busy=false,_movieEnabled=false,_weatherEnabled=false,_imageEnabled=false;
  bool _movieHasCredential=false,_weatherHasCredential=false,_imageHasCredential=false,_cleanup=false;
  WeatherProtocol _protocol=WeatherProtocol.currentV1;
  LocalWeatherAuthentication _authentication=LocalWeatherAuthentication.apiKey;
  String? _message,_movieResult;Map<String,dynamic>? _weatherResult;
  @override void initState(){super.initState();unawaited(_perform(_load));}
  @override void dispose(){for(final c in [_movieUrl,_movieFamily,_movieToken,_weatherUrl,_weatherCredential,_imageUrl,_imageModel,_imageKey,_retention]){c.dispose();}super.dispose();}
  Future<void> _load()async{
    final v=await widget.settings.readSettings();if(!mounted)return;
    _movieEnabled=v.movie.enabled;_movieUrl.text=v.movie.endpoint;_movieFamily.text=v.movie.remoteFamilyId;_movieHasCredential=v.movie.hasCredentialReference;
    _weatherEnabled=v.weather.enabled;_weatherUrl.text=v.weather.endpoint;_weatherHasCredential=v.weather.hasCredentialReference;_protocol=v.weather.protocol;_authentication=v.weather.authentication;
    _imageEnabled=v.image.enabled;_imageUrl.text=v.image.endpoint;_imageModel.text=v.image.model;_retention.text=v.image.retentionNotice;_imageHasCredential=v.image.hasCredentialReference;
    _cleanup=v.pendingCredentialCleanup;
  }
  Future<void> _perform(Future<void> Function() action,{String? success})async{
    if(_busy)return;setState((){_busy=true;_message=null;});
    try{await action();if(mounted)setState(()=>_message=success);}
    catch(e){if(e is LocalServiceSettingsException&&e.code=='credential_cleanup_failed'){try{await _load();}catch(_){}}if(mounted)setState(()=>_message=_error(e));}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  String? _take(TextEditingController c){final value=c.text;c.clear();return value.isEmpty?null:value;}
  Future<void> _saveMovie()=>_perform(()async{
    final token=_take(_movieToken);await widget.settings.saveMovie(baseUrl:Uri.parse(_movieUrl.text.trim()),remoteFamilyId:_movieFamily.text.trim(),
      enabled:_movieEnabled,bearerToken:token);_movieResult=null;await _load();
  },success:'电影查询配置已保存在本机，未联系后端或改动片单。');
  Future<void> _saveWeather()=>_perform(()async{
    final credential=_take(_weatherCredential);await widget.settings.saveWeather(baseUrl:Uri.parse(_weatherUrl.text.trim()),enabled:_weatherEnabled,
      protocol:_protocol,authentication:_authentication,credential:credential);_weatherResult=null;await _load();
  },success:'天气配置已保存在本机，没有定位或发出请求。');
  Future<void> _saveImage()=>_perform(()async{
    final key=_take(_imageKey);await widget.settings.saveImage(baseUrl:Uri.parse(_imageUrl.text.trim()),model:_imageModel.text.trim(),
      retentionNotice:_retention.text.trim(),enabled:_imageEnabled,apiKey:key);await _load();
  },success:'图片模型配置已保存在本机；尚未发送图片或提示词。');
  Future<void> _remove(String name)=>_perform(()async{await widget.settings.remove(name);if(name=='movie')_movieResult=null;if(name=='weather')_weatherResult=null;await _load();},success:'已移除这项本机配置；没有更改供应商账号。');
  Widget _field(TextEditingController controller,String label,{bool secret=false,int lines=1,String? hint})=>Padding(
    padding:const EdgeInsets.only(bottom:WoTokens.space3),child:TextField(controller:controller,enabled:!_busy,obscureText:secret,
      minLines:lines,maxLines:secret?1:(lines>1?6:1),autocorrect:false,enableSuggestions:false,
      keyboardType:secret?TextInputType.visiblePassword:(lines>1?TextInputType.multiline:TextInputType.text),
      decoration:InputDecoration(labelText:label,hintText:hint)));
  Widget _section(String title,List<Widget> children)=>Padding(padding:const EdgeInsets.only(bottom:WoTokens.space4),child:WoCard(
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:Theme.of(context).textTheme.titleMedium),const SizedBox(height:WoTokens.space3),...children])));
  @override Widget build(BuildContext context)=>WoScaffold(appBar:WoAppBar(title:const Text('本机可选服务')),body:SafeArea(top:false,child:ListView(
    padding:const EdgeInsets.all(WoTokens.space4),children:[
      const Padding(padding:EdgeInsets.only(bottom:WoTokens.space4),child:Text('记录、片单状态、旅行原照与生成结果继续保存在本机。只有你主动查询或逐次授权生成时，才调用所选服务。')),
      if(_busy)...[const LinearProgressIndicator(),const SizedBox(height:WoTokens.space4)],
      if(_message!=null)Padding(padding:const EdgeInsets.only(bottom:WoTokens.space4),child:Text(_message!)),
      if(_cleanup)_section('旧凭据清理待完成',[
        const Text('新配置可能已经生效，但部分被替换的本机凭据尚未清理。'),
        TextButton(onPressed:_busy?null:()=>_perform(()async{await widget.settings.cleanupRetiredCredentials();await _load();},success:'旧凭据已从本机安全存储移除。'),child:const Text('重试清理旧凭据')),
      ]),
      _section('电影片库查询',[
        SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('启用电影查询'),value:_movieEnabled,onChanged:_busy?null:(v)=>setState(()=>_movieEnabled=v)),
        _field(_movieUrl,'电影后端 HTTPS 地址',hint:'仅现有 discover / genres / poster 查询'),
        _field(_movieFamily,'该后端已授权的家庭标识',hint:'与本机家庭身份分开配置'),
        _field(_movieToken,'该后端的查询会话 token',secret:true,hint:_movieHasCredential?'留空保留当前地址凭据；改地址需重填':'仅保存在本机安全存储'),
        const Text('不会调用云端添加、补充或修改片单接口。后端旧片单标记不能覆盖本地状态。'),
        Wrap(spacing:WoTokens.space3,runSpacing:WoTokens.space2,children:[
          FilledButton(onPressed:_busy?null:_saveMovie,child:const Text('保存本机配置')),
          OutlinedButton(onPressed:_busy?null:()=>_perform(()async{final genres=await widget.settings.movieClient().genres();_movieResult='可读取 ${genres.length} 个片库分类；本机片单未改动。';}),child:const Text('按已保存配置查询分类')),
          TextButton(onPressed:_busy?null:()=>_remove('movie'),child:const Text('移除此项配置')),
        ]),if(_movieResult!=null)Text(_movieResult!),
      ]),
      _section('天气',[
        SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('启用天气查询'),value:_weatherEnabled,onChanged:_busy?null:(v)=>setState(()=>_weatherEnabled=v)),
        _field(_weatherUrl,'QWeather API Host（HTTPS）',hint:'只填主机地址，不带 /v7 或查询参数'),
        DropdownButton<WeatherProtocol>(isExpanded:true,value:_protocol,onChanged:_busy?null:(v){if(v!=null)setState(()=>_protocol=v);},items:const[
          DropdownMenuItem(value:WeatherProtocol.currentV1,child:Text('Current Weather v1（优先）')),
          DropdownMenuItem(value:WeatherProtocol.cityBasedV7,child:Text('城市天气 v7（明确兼容，不自动切换）')),
        ]),
        DropdownButton<LocalWeatherAuthentication>(isExpanded:true,value:_authentication,onChanged:_busy?null:(v){if(v!=null)setState(()=>_authentication=v);},items:const[
          DropdownMenuItem(value:LocalWeatherAuthentication.apiKey,child:Text('API Key header')),
          DropdownMenuItem(value:LocalWeatherAuthentication.bearerJwt,child:Text('已签发 JWT Bearer')),
        ]),
        _field(_weatherCredential,'天气凭据（两种方式仅选一种）',secret:true,hint:_weatherHasCredential?'留空保留同地址/同认证方式凭据':'凭据不会进入坐标 URL'),
        const Text('保存不定位。点下方按钮才申请设备定位权限，向所选天气服务发送两位小数坐标；不保存到家庭设置，不发送高度、速度或身份。'),
        const Text('v1 直接提供实时 UV；v7 没有该字段，不冒用其它日指数。失败时不自动换协议重发位置。'),
        Wrap(spacing:WoTokens.space3,runSpacing:WoTokens.space2,children:[
          FilledButton(onPressed:_busy?null:_saveWeather,child:const Text('保存本机配置')),
          OutlinedButton(onPressed:_busy?null:()=>_perform(()async{_weatherResult=await widget.settings.weatherClient().current();}),child:const Text('按已保存配置授权定位并查询一次')),
          TextButton(onPressed:_busy?null:()=>_remove('weather'),child:const Text('移除此项配置')),
        ]),
        if(_weatherResult!=null)...[
          const SizedBox(height:WoTokens.space3),Text('本次查询：${_weatherResult!['condition']??'—'}，${_weatherResult!['temp_c']??'—'} °C'),
          Text('湿度 ${_weatherResult!['humidity_pct']??'—'}% · UV ${_weatherResult!['uv_index']??'—'}'),
          Text('观测时间：${_weatherResult!['observed_at']??'未提供'}'),const Text('数据来源：QWeather'),
          for(final source in (_weatherResult!['attributions'] as List? ??const []))SelectableText(source as String),
        ],
      ]),
      _section('旅行图片模型',[
        SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('启用图片模型'),value:_imageEnabled,onChanged:_busy?null:(v)=>setState(()=>_imageEnabled=v)),
        _field(_imageUrl,'图片模型 HTTPS endpoint',hint:'例如 https://model.example/v1'),
        _field(_imageModel,'模型名称'),
        _field(_imageKey,'模型 API key',secret:true,hint:_imageHasCredential?'留空保留当前 endpoint 凭据；改地址需重填':'仅保存在本机安全存储'),
        _field(_retention,'供应商对输入留存的说明',lines:3,hint:'填写已核对的真实政策；不能以 no-store 代替供应商承诺'),
        const Text('此页不试传图片。到旅行记录中预览发送副本、核对当前模型与留存说明，每次明确授权后才生成。原照与生成结果均在本机保留。'),
        const Text('这里只配置旅行图片模型；旧 AI 集成入口其它能力尚未迁移，不能据此视为全部 AI 功能已完成。'),
        Wrap(spacing:WoTokens.space3,runSpacing:WoTokens.space2,children:[
          FilledButton(onPressed:_busy?null:_saveImage,child:const Text('保存本机配置')),
          TextButton(onPressed:_busy?null:()=>_remove('image'),child:const Text('移除此项配置')),
        ]),
      ]),
      const Text('这些配置与凭据不进入家庭同步或电脑业务备份。更换设备后需重新配置；移除本机凭据不会自动吊销供应商凭据。'),
    ])));
}
String _error(Object error){
  if(error is LocalServiceSettingsException)return switch(error.code){
    'invalid_endpoint'=>'请填写不含账号、查询参数的 HTTPS 地址。',
    'credential_reentry_required'=>'地址或认证方式改变，请明确重新输入对应服务的凭据，旧凭据不会自动转发到新地址。',
    'credential_required'=>'启用前需要设置这项服务的凭据。',
    'invalid_credential'=>'凭据格式无效，请核对内容，不要加入空格或换行。',
    'model_policy_required'=>'请填写模型名称及真实供应商输入留存说明。',
    'credential_cleanup_failed'=>'新配置已保存，但旧本机凭据清理未完成，请重试清理。',
    _=>'本机配置暂不可用，没有改动业务资料或联系旧云设置。',
  };
  if(error is ExternalServiceException)return switch(error.failure){
    ServiceFailure.notConfigured=>'该服务尚未启用或本机凭据不可用，请先保存配置。',
    ServiceFailure.locationDenied=>'未取得定位授权或有效位置，没有发送天气请求。',
    ServiceFailure.invalidInput=>'配置或输入无效，没有提交此次查询。',
    _=>'所选服务此次查询未完成，本机记录仍保留；不会自动改用其它服务。',
  };
  return '此次操作未完成，请核对本机配置后显式重试。';
}
