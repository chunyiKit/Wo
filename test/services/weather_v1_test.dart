import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wo/services/external_services.dart';

Map<String,dynamic> currentFixture()=>{
  'metadata':{'tag':'synthetic','attributions':['https://developer.qweather.com/attribution.html']},
  'validTime':'2026-11-20T03:15Z','condition':{'text':'Synthetic clouds','code':'102'},
  'temperature':{'value':21.71,'unit':'°C'},'feelsLike':{'value':23.64,'unit':'°C'},'humidity':0.69,
  'wind':{'direction':{'degree':226,'compass':'sw'},'speed':{'value':4.74,'unit':'m/s'},'scale':3},
  'precipitation':{'amount':{'value':0.0,'unit':'mm'},'intensity':{'value':0.0,'unit':'mm/h'},'type':'none'},
  'pressure':{'value':1001.5,'unit':'hPa'},'visibility':{'value':29020,'unit':'m'},
  'dewPoint':{'value':15.36,'unit':'°C'},'cloudCover':0.05,'uvIndex':0,
};
WeatherServiceConfig v1({String apiKey='synthetic-key',String bearerToken=''})=>WeatherServiceConfig(
  baseUrl:Uri.parse('https://weather.example'),protocol:WeatherProtocol.currentV1,apiKey:apiKey,bearerToken:bearerToken);
http.Response reply(Object body,{int status=200})=>http.Response(jsonEncode(body),status,headers:{'content-type':'application/json'});
Matcher failure(ServiceFailure expected)=>isA<ExternalServiceException>().having((e)=>e.failure,'failure',expected);
void main(){
  test('v1 sends rounded latitude then longitude, one request and header key only',()async{
    var calls=0,locations=0;final client=WeatherClient(loadConfig:()async=>v1(),locateWithPermission:()async{locations++;return const AuthorizedLocation(12.34567,45.67891);},
      client:MockClient((request)async{
        calls++;expect(request.url.path,'/weather/v1/current/12.35/45.68');expect(request.url.queryParameters,isEmpty);
        expect(request.method,'GET');expect(request.body,isEmpty);expect(request.followRedirects,false);
        expect(request.headers['X-QW-Api-Key']??request.headers['x-qw-api-key'],'synthetic-key');
        expect(request.headers.containsKey('Authorization'),false);expect(request.url.toString(),isNot(contains('synthetic-key')));
        return reply(currentFixture());
      }));
    expect(calls,0);expect(locations,0);final result=await client.current();expect(calls,1);expect(locations,1);
    expect(result['humidity_pct'],69);expect(result['cloud_pct'],5);expect(result['wind_speed_kmh'],closeTo(17.064,0.000001));
    expect(result['visibility_km'],closeTo(29.02,0.000001));expect(result['uv_index'],0);expect(result['wind_scale'],'3');
    expect(result['temp_c'],21.71);expect(result['pressure_hpa'],1001.5);expect(result['protocol'],'currentV1');
    expect(result['attributions'],['https://developer.qweather.com/attribution.html']);
    expect(result.keys.any((key)=>{'key','api_key','token','device','family','altitude','speed','bearing'}.contains(key)),false);
  });
  test('JWT is explicit alternative to API key, never both and never query auth',()async{
    final client=WeatherClient(loadConfig:()async=>v1(apiKey:'',bearerToken:'synthetic.jwt.value'),locateWithPermission:()async=>const AuthorizedLocation(0,-0.01),
      client:MockClient((r)async{
        expect(r.headers['Authorization']??r.headers['authorization'],'Bearer synthetic.jwt.value');
        expect(r.headers.keys.any((k)=>k.toLowerCase()=='x-qw-api-key'),false);expect(r.url.queryParameters,isEmpty);return reply(currentFixture());
      }));await client.current();
    expect(()=>v1(bearerToken:'synthetic.jwt.value'),throwsA(failure(ServiceFailure.invalidInput)));
    expect(()=>WeatherServiceConfig(baseUrl:Uri.parse('https://weather.example/v7'),protocol:WeatherProtocol.currentV1,apiKey:'synthetic'),throwsA(failure(ServiceFailure.invalidInput)));
    expect(()=>v1(apiKey:'synthetic\nkey'),throwsA(failure(ServiceFailure.invalidInput)));
  });
  test('missing config and refused permission do not send position, GET or settings mutation',()async{
    var calls=0,positions=0;final transport=MockClient((_)async{calls++;return reply({});});
    final unconfigured=WeatherClient(loadConfig:()async=>v1(apiKey:''),locateWithPermission:()async{positions++;return const AuthorizedLocation(12,34);},client:transport);
    await expectLater(unconfigured.current(),throwsA(failure(ServiceFailure.notConfigured)));expect(positions,0);
    final denied=WeatherClient(loadConfig:()async=>v1(),locateWithPermission:()async{positions++;return null;},client:transport);
    await expectLater(denied.current(),throwsA(failure(ServiceFailure.locationDenied)));expect(positions,1);expect(calls,0);
  });
  test('unknown units, wrong scalar types and unreasonable v1 values fail rather than become available',()async{
    final mutations=<void Function(Map<String,dynamic>)>[
      (j)=>(j['temperature'] as Map)['unit']='°F',
      (j)=>(j['wind']['speed'] as Map)['unit']='km/h',
      (j)=>(j['visibility'] as Map)['unit']='km',
      (j)=>(j['pressure'] as Map)['unit']='Pa',
      (j)=>(j['precipitation']['amount'] as Map)['unit']='in',
      (j)=>j['humidity']=69,(j)=>j['cloudCover']=-0.1,(j)=>j['uvIndex']=16,
      (j)=>(j['temperature'] as Map)['value']='21.71',
      (j)=>(j['temperature'] as Map)['value']=10000,
      (j)=>(j['wind']['speed'] as Map)['value']=-1,
      (j)=>(j['visibility'] as Map)['value']=-1,
      (j)=>j['validTime']='not-time',(j)=>j.remove('temperature'),
    ];
    for(final mutate in mutations){var calls=0;final fixture=currentFixture();mutate(fixture);
      final client=WeatherClient(loadConfig:()async=>v1(),locateWithPermission:()async=>const AuthorizedLocation(1,2),client:MockClient((_)async{calls++;return reply(fixture);}));
      await expectLater(client.current(),throwsA(failure(ServiceFailure.invalidResponse)));expect(calls,1);
    }
  });
  test('remote v1 errors and legacy-shaped success do not leak input or automatically fallback to v7',()async{
    for(final status in [200,404,503]){final paths=<String>[];final client=WeatherClient(loadConfig:()async=>v1(),locateWithPermission:()async=>const AuthorizedLocation(1.23456,2.34567),
      client:MockClient((r)async{paths.add(r.url.path);return reply(status==200?{'code':'200','now':{'temp':'20'}}:{'error':'synthetic private server text'},status:status);}));
      try{await client.current();fail('expected failure');}on ExternalServiceException catch(e){expect('$e',isNot(contains('synthetic')));expect('$e',isNot(contains('1.23456')));}
      expect(paths,['/weather/v1/current/1.23/2.35']);
    }
  });
  test('zero and boundary ratios remain meaningful; absent optional metrics stay null',()async{
    final fixture=currentFixture();fixture['humidity']=0;fixture['cloudCover']=1;for(final field in ['wind','visibility','pressure','dewPoint']){fixture.remove(field);}
    final client=WeatherClient(loadConfig:()async=>v1(),locateWithPermission:()async=>const AuthorizedLocation(-12.345,-45.678),client:MockClient((_)async=>reply(fixture)));
    final result=await client.current();expect(result['humidity_pct'],0);expect(result['cloud_pct'],100);expect(result['uv_index'],0);
    expect(result['wind_speed_kmh'],isNull);expect(result['visibility_km'],isNull);expect(result['pressure_hpa'],isNull);
  });
}
