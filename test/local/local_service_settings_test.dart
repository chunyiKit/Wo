import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/local/local_service_settings.dart';
import 'package:wo/local/local_store.dart';
import 'package:wo/services/external_services.dart';
import 'backup/mobile_backup_client_test.dart' show TestCrypto;
class _Crypto extends TestCrypto {
  int reads=0;bool failDelete=false;
  @override Future<Uint8List?> getSecret(String handle)async{reads++;return super.getSecret(handle);}
  @override Future<void> deleteSecret(String handle)async{if(failDelete)throw StateError('synthetic failure');await super.deleteSecret(handle);}
}
void main(){
  sqfliteFfiInit();late Directory directory;late LocalStore store;late _Crypto crypto;
  late LocalServiceSettings settings;var requests=0,locations=0;
  setUp(()async{
    directory=await Directory.systemTemp.createTemp('wo-services-synthetic-');store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/local.sqlite');
    crypto=_Crypto();requests=0;locations=0;
    settings=LocalServiceSettings(store:store,crypto:crypto,locateWithPermission:()async{locations++;return null;},client:MockClient((r)async{
      requests++;expect(r.method,'GET');expect(r.url.path,'/api/v1/families/remote-family/plugins/movie/discover/genres');
      expect(r.headers['Authorization']??r.headers['authorization'],'Bearer synthetic-movie-token');
      return http.Response(jsonEncode({'success':true,'data':[{'id':18,'name':'Synthetic genre'}]}),200);
    }));
  });
  tearDown(()async{settings.close();await store.close();await directory.delete(recursive:true);});
  test('read metadata and construct clients never contact native secret, location or HTTP',()async{
    final view=await settings.readSettings();settings.movieClient();settings.weatherClient();settings.imageClient();
    expect(view.weather.protocol,WeatherProtocol.currentV1);expect(view.weather.enabled,false);
    expect([crypto.reads,locations,requests],[0,0,0]);
  });
  test('credentials live only in native refs; readonly movie identity is explicit and state logs remain empty',()async{
    await settings.saveMovie(baseUrl:Uri.parse('https://movie.example'),remoteFamilyId:'remote-family',enabled:true,bearerToken:'synthetic-movie-token');
    final metadata=await store.privateValue(LocalServiceSettings.privateKey);expect(jsonEncode(metadata),isNot(contains('synthetic-movie-token')));
    expect(metadata['movie']['credential_ref'],startsWith('wo.services.movie.'));expect(requests,0);expect(crypto.reads,0);
    expect(await store.db.query('documents'),isEmpty);expect(await store.db.query('operations'),isEmpty);expect(await store.exportSince('family',{}),isEmpty);
    expect(await settings.movieClient().genres(),[{'id':18,'name':'Synthetic genre'}]);expect(requests,1);
    expect((await settings.loadMovieConfig())!.remoteFamilyId,isNot(store.deviceId));
  });
  test('weather defaults explicit v1, denial sends no HTTP and no coordinates are saved',()async{
    await settings.saveWeather(baseUrl:Uri.parse('https://weather.example'),enabled:true,credential:'synthetic-weather-key');
    expect((await settings.loadWeatherConfig())!.protocol,WeatherProtocol.currentV1);expect(locations,0);expect(requests,0);
    await expectLater(settings.weatherClient().current(),throwsA(isA<ExternalServiceException>().having((e)=>e.failure,'failure',ServiceFailure.locationDenied)));
    expect(locations,1);expect(requests,0);final raw=jsonEncode(await store.privateValue(LocalServiceSettings.privateKey));
    expect(raw,isNot(contains('synthetic-weather-key')));expect(raw,isNot(contains('latitude')));expect(raw,isNot(contains('longitude')));
    expect(await store.db.query('documents'),isEmpty);expect(await store.db.query('operations'),isEmpty);
  });
  test('rebind endpoint or auth requires explicit new credential; old secret is not forwarded',()async{
    await settings.saveMovie(baseUrl:Uri.parse('https://movie.example'),remoteFamilyId:'remote-family',enabled:true,bearerToken:'synthetic-old-token');
    await expectLater(settings.saveMovie(baseUrl:Uri.parse('https://other.example'),remoteFamilyId:'remote-family',enabled:true),
      throwsA(isA<LocalServiceSettingsException>().having((e)=>e.code,'code','credential_reentry_required')));
    expect((await settings.loadMovieConfig())!.baseUrl.host,'movie.example');expect(requests,0);
    await settings.saveWeather(baseUrl:Uri.parse('https://weather.example'),enabled:true,credential:'synthetic-key');
    await expectLater(settings.saveWeather(baseUrl:Uri.parse('https://weather.example'),enabled:true,authentication:LocalWeatherAuthentication.bearerJwt),
      throwsA(isA<LocalServiceSettingsException>().having((e)=>e.code,'code','credential_reentry_required')));
    expect((await settings.loadWeatherConfig())!.apiKey,'synthetic-key');
  });
  test('image enabled requires endpoint/model/policy and saves nothing to old cloud AI settings',()async{
    await expectLater(settings.saveImage(baseUrl:Uri.parse('https://model.example/v1'),model:'synthetic-model',retentionNotice:'',enabled:true,apiKey:'synthetic-image-key'),
      throwsA(isA<LocalServiceSettingsException>().having((e)=>e.code,'code','model_policy_required')));
    expect(crypto.secrets,isEmpty);
    await settings.saveImage(baseUrl:Uri.parse('https://model.example/v1'),model:'synthetic-model',retentionNotice:'合成供应商留存政策',enabled:true,apiKey:'synthetic-image-key');
    final config=await settings.loadImageConfig();expect(config!.model,'synthetic-model');expect(config.retentionNotice,'合成供应商留存政策');expect(requests,0);
    final meta=await store.db.query('meta');expect(meta.where((r)=>(r['key'] as String).startsWith('private:')).single['key'],'private:${LocalServiceSettings.privateKey}');
    expect(jsonEncode(meta),isNot(contains('synthetic-image-key')));expect(await store.db.query('operations'),isEmpty);
  });
  test('replacement cleanup failure retains retryable reference without changing active config',()async{
    await settings.saveMovie(baseUrl:Uri.parse('https://movie.example'),remoteFamilyId:'remote-family',enabled:true,bearerToken:'synthetic-old');
    final old=(await store.privateValue(LocalServiceSettings.privateKey))['movie']['credential_ref'] as String;
    crypto.failDelete=true;
    await expectLater(settings.saveMovie(baseUrl:Uri.parse('https://movie.example'),remoteFamilyId:'remote-family',enabled:true,bearerToken:'synthetic-new'),
      throwsA(isA<LocalServiceSettingsException>().having((e)=>e.code,'code','credential_cleanup_failed')));
    expect((await settings.loadMovieConfig())!.bearerToken,'synthetic-new');expect((await settings.readSettings()).pendingCredentialCleanup,true);
    expect(crypto.secrets.containsKey(old),true);crypto.failDelete=false;await settings.cleanupRetiredCredentials();expect(crypto.secrets.containsKey(old),false);
    expect((await settings.readSettings()).pendingCredentialCleanup,false);expect((await settings.loadMovieConfig())!.bearerToken,'synthetic-new');
  });
  test('forged cross-service reference cannot read native backup or image secret',()async{
    await store.setPrivate(LocalServiceSettings.privateKey,{'v':1,'retired_refs':<String>[],
      'movie':{'enabled':true,'endpoint':'https://movie.example','remote_family':'remote-family','credential_ref':'wo.backup.token.${'1'*32}'}});
    await expectLater(settings.loadMovieConfig(),throwsA(isA<LocalServiceSettingsException>()));expect(crypto.reads,0);expect(requests,0);
  });
  test('one malformed service does not make another healthy loader unavailable',()async{
    await settings.saveMovie(baseUrl:Uri.parse('https://movie.example'),remoteFamilyId:'remote-family',enabled:true,bearerToken:'synthetic-movie-token');
    final raw=Map<String,dynamic>.from(await store.privateValue(LocalServiceSettings.privateKey) as Map);
    raw['weather']={'enabled':true,'endpoint':'https://weather.example','protocol':'unsupported-synthetic','auth':'apiKey'};
    await store.setPrivate(LocalServiceSettings.privateKey,raw);
    expect((await settings.loadMovieConfig())!.remoteFamilyId,'remote-family');
    await expectLater(settings.loadWeatherConfig(),throwsA(isA<LocalServiceSettingsException>()));expect(locations,0);expect(requests,0);
  });
  test('missing native secret only disables its service and never prompts for position',()async{
    await settings.saveWeather(baseUrl:Uri.parse('https://weather.example'),enabled:true,credential:'synthetic-weather-key');crypto.secrets.clear();
    await expectLater(settings.weatherClient().current(),throwsA(isA<ExternalServiceException>().having((e)=>e.failure,'failure',ServiceFailure.notConfigured)));
    expect(locations,0);expect(requests,0);expect((await settings.readSettings()).weather.enabled,true);
  });
}
