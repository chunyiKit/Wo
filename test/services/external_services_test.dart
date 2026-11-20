import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wo/services/external_services.dart';

final pixel = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
http.Response jsonResponse(Object body, {int status = 200}) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
http.Response envelope(Object data) => jsonResponse({'success': true, 'data': data});
Matcher failure(ServiceFailure code) => isA<ExternalServiceException>().having((e) => e.failure, 'failure', code);
MovieBackendConfig movieConfig() => MovieBackendConfig(baseUrl: Uri.parse('https://movie.example'), remoteFamilyId: 'remote-family', bearerToken: 'test-only-movie-token');
WeatherServiceConfig weatherConfig() => WeatherServiceConfig(baseUrl: Uri.parse('https://weather.example/v7'), apiKey: 'test-only-weather-key');
ImageModelConfig modelConfig({Iterable<Uri> resultOrigins = const []}) => ImageModelConfig(baseUrl: Uri.parse('https://model.example/v1'), apiKey: 'test-only-model-key', model: 'test-image-model', retentionNotice: '合成测试：配置者已查看供应商输入留存政策', resultOrigins: resultOrigins);
ImageGenerationConsent consent(ImageModelConfig config) => ImageGenerationConsent(endpoint: config.baseUrl, retentionNotice: config.retentionNotice, allowSourceUpload: true, providerPolicyReviewed: true);

class StreamingClient extends http.BaseClient {
  StreamingClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handler(request);
}

void main() {
  test('构造不发网络，配置缺失不定位也不触发服务', () async {
    var calls = 0, positions = 0;
    final httpClient = MockClient((_) async { calls++; return envelope([]); });
    final movies = MovieCatalogueClient(loadConfig: () async => null, client: httpClient);
    final weather = WeatherClient(loadConfig: () async => null, locateWithPermission: () async { positions++; return null; }, client: httpClient);
    final images = ConfiguredImageClient(loadConfig: () async => null, client: httpClient);
    expect(calls, 0);
    await expectLater(movies.genres(), throwsA(failure(ServiceFailure.notConfigured)));
    await expectLater(weather.current(), throwsA(failure(ServiceFailure.notConfigured)));
    await expectLater(images.generate(image: PreparedModelImage(pixel), prompt: 'synthetic', consent: consent(modelConfig())), throwsA(failure(ServiceFailure.notConfigured)));
    expect(calls, 0); expect(positions, 0);
  });

  test('电影只调用现有查询 GET，后端旧片单状态被本地集合覆盖', () async {
    final requests = <http.Request>[];
    final client = MovieCatalogueClient(loadConfig: () async => movieConfig(), client: MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/genres')) return envelope([{'id': 18, 'name': '剧情'}]);
      return envelope([
        {'tmdb_id': 1, 'title': 'synthetic one', 'already_added': true, 'watched': true, 'private_note': 'must-drop', 'poster_url': '/api/v1/families/remote-family/plugins/movie/discover/poster?path=%2Fposter.jpg'},
        {'tmdb_id': 2, 'title': 'synthetic two', 'already_added': false, 'poster_url': 'https://unapproved.example/file.png'},
      ]);
    }));
    expect(await client.genres(), [{'id': 18, 'name': '剧情'}]);
    final result = await client.discover(genreIds: [18,18], sort: 'rating', page: 2, locallyAddedTmdbIds: {2});
    expect(result[0]['already_added'], false); expect(result[1]['already_added'], true);
    expect(result[0].containsKey('watched'), false); expect(result[0].containsKey('private_note'), false);
    expect(result[0]['poster_url'], startsWith('/api/v1/')); expect(result[1]['poster_url'], isNull);
    expect(requests.every((r) => r.method == 'GET' && r.body.isEmpty && !r.followRedirects), true);
    expect(requests.last.url.queryParameters, {'genres': '18', 'sort': 'rating', 'page': '2'});
    expect(requests.last.headers['Authorization'] ?? requests.last.headers['authorization'], 'Bearer test-only-movie-token');
    expect(requests.last.url.toString(), isNot(contains('local')));
  });

  test('电影非法查询/海报路径不发送请求，现有海报只走固定后端', () async {
    var calls = 0;
    final client = MovieCatalogueClient(loadConfig: () async => movieConfig(), client: MockClient((request) async {
      calls++;
      expect(request.url.path, '/api/v1/families/remote-family/plugins/movie/discover/poster');
      expect(request.url.queryParameters, {'path': '/synthetic.jpg'});
      return http.Response.bytes(pixel, 200);
    }));
    await expectLater(client.discover(sort: 'unsupported'), throwsA(failure(ServiceFailure.invalidInput)));
    await expectLater(client.discover(page: 0), throwsA(failure(ServiceFailure.invalidInput)));
    await expectLater(client.poster('/../../private.jpg'), throwsA(failure(ServiceFailure.invalidInput)));
    await expectLater(client.poster('https://other.example/a.jpg'), throwsA(failure(ServiceFailure.invalidInput)));
    expect(calls, 0);
    expect((await client.poster('/synthetic.jpg')).bytes, pixel); expect(calls, 1);
  });

  test('电影不跟随重定向，错误和配置回调异常不泄露响应正文或凭据', () async {
    var calls = 0;
    final client = MovieCatalogueClient(loadConfig: () async => movieConfig(), client: MockClient((_) async {
      calls++; return http.Response('test-only-movie-token private-response', 302, headers: {'location': 'https://evil.example'});
    }));
    try { await client.genres(); fail('expected failure'); }
    on ExternalServiceException catch (e) { expect(e.failure, ServiceFailure.remoteStatus); expect('$e', isNot(contains('token'))); expect('$e', isNot(contains('private-response'))); }
    expect(calls, 1);
    final bad = MovieCatalogueClient(loadConfig: () async => throw StateError('secret credential'), client: MockClient((_) async => envelope([])));
    await expectLater(bad.genres(), throwsA(failure(ServiceFailure.notConfigured)));
  });

  test('配置拒绝明文远程地址/URL凭据，只为显式合成回环允许 HTTP', () {
    expect(() => MovieBackendConfig(baseUrl: Uri.parse('http://public.example'), remoteFamilyId: 'f', bearerToken: 'test-only'), throwsA(failure(ServiceFailure.invalidInput)));
    expect(() => modelConfig().resultOrigins.add(Uri.parse('https://evil.example')), throwsUnsupportedError);
    expect(() => WeatherServiceConfig(baseUrl: Uri.parse('https://user:pass@weather.example'), apiKey: 'test-only'), throwsA(failure(ServiceFailure.invalidInput)));
    final local = WeatherServiceConfig(baseUrl: Uri.parse('http://127.0.0.1:9000/v7'), apiKey: 'test-only', allowInsecureLoopback: true);
    expect(local.baseUrl.scheme, 'http');
  });

  test('拒绝定位或定位异常时没有天气网络请求', () async {
    var calls = 0;
    final httpClient = MockClient((_) async { calls++; return jsonResponse({}); });
    final denied = WeatherClient(loadConfig: () async => weatherConfig(), locateWithPermission: () async => null, client: httpClient);
    await expectLater(denied.current(), throwsA(failure(ServiceFailure.locationDenied)));
    final error = WeatherClient(loadConfig: () async => weatherConfig(), locateWithPermission: () async => throw StateError('position detail'), client: httpClient);
    await expectLater(error.current(), throwsA(failure(ServiceFailure.locationDenied)));
    expect(calls, 0);
  });

  test('天气仅发送既有协议必需字段与降低精度位置，不写远端家庭设置', () async {
    final requests = <http.Request>[];
    final client = WeatherClient(loadConfig: () async => weatherConfig(), locateWithPermission: () async => const AuthorizedLocation(12.34567, 45.67891), client: MockClient((request) async {
      requests.add(request);
      expect(request.method, 'GET'); expect(request.body, '');
      expect(request.url.queryParameters['location'], '45.68,12.35');
      expect(request.url.queryParameters.keys.toSet(), request.url.path.endsWith('/now') ? {'location','key'} : {'location','key','type'});
      if (request.url.path.endsWith('/now')) return jsonResponse({'code':'200','updateTime':'2026-11-20T00:00:00Z','now':{'temp':'20','humidity':'50','text':'晴'}});
      return jsonResponse({'code':'200','daily':[{'level':'2'}]});
    }));
    final result = await client.current();
    expect(result['temp_c'], 20); expect(result['humidity_pct'], 50); expect(result['uv_index'], 2);
    expect(result['latitude'], 12.35); expect(result['longitude'], 45.68);
    expect(result.containsKey('key'), false); expect(requests, hasLength(2));
    expect(requests.every((r) => !r.url.path.contains('families') && !r.url.path.contains('settings')), true);
  });

  test('可选 UV 失败保留天气；无效/非有限坐标不会出站', () async {
    var calls = 0;
    final transport = MockClient((request) async {
      calls++;
      if (request.url.path.endsWith('/now')) return jsonResponse({'code':'200','now':{'temp':'20'}});
      return http.Response('synthetic failure', 503);
    });
    final client = WeatherClient(loadConfig: () async => weatherConfig(), locateWithPermission: () async => const AuthorizedLocation(1, 2), client: transport);
    expect((await client.current())['temp_c'], 20); expect(calls, 2);
    for (final location in [const AuthorizedLocation(91, 2), AuthorizedLocation(double.nan, 2)]) {
      final invalid = WeatherClient(loadConfig: () async => weatherConfig(), locateWithPermission: () async => location, client: transport);
      await expectLater(invalid.current(), throwsA(failure(ServiceFailure.invalidInput)));
    }
    expect(calls, 2);
  });

  test('天气坏响应不假装可用，不把供应商错误文本暴露给 UI', () async {
    final client = WeatherClient(loadConfig: () async => weatherConfig(), locateWithPermission: () async => const AuthorizedLocation(1, 2), client: MockClient((_) async => jsonResponse({'code':'200','now':{}})));
    await expectLater(client.current(), throwsA(failure(ServiceFailure.invalidResponse)));
  });

  test('模型输入副本不可变，拒绝 EXIF、PNG 文本和不支持的格式', () {
    final raw = Uint8List.fromList(pixel);
    final prepared = PreparedModelImage(raw);
    raw[0] = 0; expect(prepared.bytes[0], 137);
    expect(() => prepared.bytes[0] = 0, throwsUnsupportedError);
    expect(() => PreparedModelImage([0xff,0xd8,0xff,0xe1,0,2,0xff,0xd9]), throwsA(failure(ServiceFailure.invalidInput)));
    // 多扫描 JPEG 在 SOS 后追加 APP1，也不能通过。
    expect(() => PreparedModelImage([0xff,0xd8,0xff,0xda,0,2,1,0xff,0xe1,0,2,0xff,0xd9]), throwsA(failure(ServiceFailure.invalidInput)));
    final withExif = <int>[...pixel.take(8),0,0,0,0,...ascii.encode('eXIf'),0,0,0,0,...pixel.skip(8)];
    expect(() => PreparedModelImage(withExif), throwsA(failure(ServiceFailure.invalidInput)));
    expect(() => PreparedModelImage(ascii.encode('GIF89a private metadata')), throwsA(failure(ServiceFailure.invalidInput)));
  });

  test('模型必须有本次端点/留存说明对应的明确同意，否则不上传', () async {
    var calls = 0;
    final config = modelConfig();
    final client = ConfiguredImageClient(loadConfig: () async => config, client: MockClient((_) async { calls++; return jsonResponse({}); }));
    for (final c in [
      ImageGenerationConsent(endpoint: config.baseUrl, retentionNotice: config.retentionNotice, allowSourceUpload: false, providerPolicyReviewed: true),
      ImageGenerationConsent(endpoint: config.baseUrl, retentionNotice: config.retentionNotice, allowSourceUpload: true, providerPolicyReviewed: false),
      ImageGenerationConsent(endpoint: Uri.parse('https://other.example/v1'), retentionNotice: config.retentionNotice, allowSourceUpload: true, providerPolicyReviewed: true),
      ImageGenerationConsent(endpoint: config.baseUrl, retentionNotice: 'old policy', allowSourceUpload: true, providerPolicyReviewed: true),
    ]) {
      await expectLater(client.generate(image: PreparedModelImage(pixel), prompt: 'synthetic', consent: c), throwsA(failure(ServiceFailure.consentRequired)));
    }
    expect(calls, 0);
  });

  test('图片生成只提交模型必要载荷，不写云旅行记录/文件或删除本地原照', () async {
    final source = Uint8List.fromList(pixel), config = modelConfig();
    var calls = 0;
    final client = ConfiguredImageClient(loadConfig: () async => config, client: MockClient((request) async {
      calls++; expect(request.url.toString(), 'https://model.example/v1/images/generations');
      expect(request.method, 'POST'); expect(request.followRedirects, false);
      expect(request.headers['Authorization'] ?? request.headers['authorization'], 'Bearer test-only-model-key');
      final body = jsonDecode(request.body) as Map;
      expect(body.keys.toSet(), {'model','prompt','size','response_format','watermark','image'});
      expect(body['image'], 'data:image/png;base64,${base64Encode(pixel)}');
      expect(body['response_format'], 'b64_json');
      return jsonResponse({'data':[{'b64_json':base64Encode(pixel)}]});
    }));
    final result = await client.generate(image: PreparedModelImage(source), prompt: 'synthetic restyle', consent: consent(config));
    expect(result.bytes, pixel); expect(result.contentType, 'image/png'); expect(source, pixel); expect(calls, 1);
  });

  test('供应商结果 CDN 仅显式允许来源且不收到模型凭据', () async {
    final config = modelConfig(resultOrigins: [Uri.parse('https://cdn.example')]);
    var calls = 0;
    final client = ConfiguredImageClient(loadConfig: () async => config, client: MockClient((request) async {
      calls++;
      if (request.method == 'POST') return jsonResponse({'data':[{'url':'https://cdn.example/result.png?test-only-signed=1'}]});
      expect(request.url.host, 'cdn.example'); expect(request.headers.keys.any((key) => key.toLowerCase() == 'authorization'), false);
      expect(request.followRedirects, false); return http.Response.bytes(pixel, 200);
    }));
    expect((await client.generate(image: PreparedModelImage(pixel), prompt: 'synthetic', consent: consent(config))).bytes, pixel);
    expect(calls, 2);
  });

  test('不允许结果 URL SSRF/任意域名或认证转跳，也不自动重试', () async {
    final config = modelConfig();
    for (final url in ['http://127.0.0.1/private','https://unapproved.example/result.png','https://user:secret@model.example/result.png']) {
      var calls = 0;
      final client = ConfiguredImageClient(loadConfig: () async => config, client: MockClient((_) async { calls++; return jsonResponse({'data':[{'url':url}]}); }));
      await expectLater(client.generate(image: PreparedModelImage(pixel), prompt: 'synthetic', consent: consent(config)), throwsA(failure(ServiceFailure.invalidResponse)));
      expect(calls, 1);
    }
    final redirected = ConfiguredImageClient(loadConfig: () async => config, client: MockClient((_) async => http.Response('test-only-model-key synthetic-private-prompt', 307, headers: {'location':'https://unapproved.example'})));
    try { await redirected.generate(image: PreparedModelImage(pixel), prompt: 'synthetic-private-prompt', consent: consent(config)); fail('expected error'); }
    on ExternalServiceException catch (e) { expect('$e', isNot(contains('key'))); expect('$e', isNot(contains('private-prompt'))); expect(e.requestMayHaveBeenSent, true); }
  });

  test('模型错误图像和超时按安全失败处理', () async {
    final config = modelConfig();
    final malformed = ConfiguredImageClient(loadConfig: () async => config, client: MockClient((_) async => jsonResponse({'data':[{'b64_json':base64Encode(ascii.encode('not an image'))}]})));
    await expectLater(malformed.generate(image: PreparedModelImage(pixel), prompt: 'synthetic', consent: consent(config)), throwsA(failure(ServiceFailure.invalidResponse)));
    final slow = ConfiguredImageClient(loadConfig: () async => config, timeout: const Duration(milliseconds: 1), client: MockClient((_) => Completer<http.Response>().future));
    await expectLater(slow.generate(image: PreparedModelImage(pixel), prompt: 'synthetic', consent: consent(config)), throwsA(failure(ServiceFailure.network)));
  });
  test('声明过大响应会取消流，不读取整包或越界 JSON', () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(onCancel: () { cancelled = true; });
    final client = MovieCatalogueClient(loadConfig: () async => movieConfig(),
      client: StreamingClient((_) async => http.StreamedResponse(stream.stream, 200,
        contentLength: 4 * 1024 * 1024 + 1)));
    await expectLater(client.genres(), throwsA(failure(ServiceFailure.invalidResponse)));
    expect(cancelled, true);
    await stream.close();
  });

}
