import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

enum ServiceFailure {
  notConfigured,
  locationDenied,
  invalidInput,
  consentRequired,
  network,
  remoteStatus,
  invalidResponse,
}

/// 对外错误不包含 URL 查询、认证、位置、照片、提示词或供应商响应正文。
class ExternalServiceException implements Exception {
  const ExternalServiceException(this.service, this.failure,
      {this.requestMayHaveBeenSent = false});
  final String service;
  final ServiceFailure failure;
  final bool requestMayHaveBeenSent;
  @override
  String toString() => '$service 暂不可用 (${failure.name})';
}

Uri _base(Uri value, {bool allowInsecureLoopback = false}) {
  final loopback = ['127.0.0.1', 'localhost', '::1'].contains(value.host);
  if (!value.hasAuthority || value.host.isEmpty || value.userInfo.isNotEmpty ||
      value.hasQuery || value.hasFragment ||
      (value.scheme != 'https' && !(allowInsecureLoopback && loopback && value.scheme == 'http'))) {
    throw const ExternalServiceException('配置', ServiceFailure.invalidInput);
  }
  return value.replace(path: value.path.replaceFirst(RegExp(r'/+$'), ''));
}

Uri _route(Uri base, String path, [Map<String, String>? query]) =>
    base.replace(path: '${base.path}/$path', queryParameters: query);

Future<T?> _configuration<T>(Future<T?> Function() load, String service) async {
  try { return await load(); } catch (_) { throw ExternalServiceException(service, ServiceFailure.notConfigured); }
}

Uri _origin(Uri uri) => Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null);

class _Transport {
  _Transport(this.client, this.name, this.timeout);
  final http.Client client;
  final String name;
  final Duration timeout;
  Future<({Uint8List bytes, String type})> send(http.Request request, int limit) async {
    request.followRedirects = false;
    request.headers['Cache-Control'] = 'no-store';
    try {
      final response = await client.send(request).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen((_) {}).cancel().timeout(timeout);
        throw ExternalServiceException(name, ServiceFailure.remoteStatus,
            requestMayHaveBeenSent: true);
      }
      if (response.contentLength != null && response.contentLength! > limit) {
        await response.stream.listen((_) {}).cancel().timeout(timeout);
        throw ExternalServiceException(name, ServiceFailure.invalidResponse,
            requestMayHaveBeenSent: true);
      }
      final output = BytesBuilder(copy: false);
      final iterator = StreamIterator<List<int>>(response.stream);
      try {
        await (() async {
          while (await iterator.moveNext()) {
            final part = iterator.current;
            if (output.length + part.length > limit) {
              throw ExternalServiceException(name, ServiceFailure.invalidResponse,
                  requestMayHaveBeenSent: true);
            }
            output.add(part);
          }
        })().timeout(timeout);
      } finally {
        await iterator.cancel().timeout(timeout);
      }
      return (bytes: output.takeBytes(), type: response.headers['content-type']?.split(';').first ?? '');

    } on ExternalServiceException {
      rethrow;
    } catch (_) {
      throw ExternalServiceException(name, ServiceFailure.network,
          requestMayHaveBeenSent: true);
    }
  }

  Future<dynamic> json(http.Request request, {int limit = 4 * 1024 * 1024}) async {
    final response = await send(request, limit);
    try {
      return jsonDecode(utf8.decode(response.bytes));
    } catch (_) {
      throw ExternalServiceException(name, ServiceFailure.invalidResponse,
          requestMayHaveBeenSent: true);
    }
  }
}

/// 与本地家庭身份分离的可选后端查询配置；不提供持久化/序列化方法。
class MovieBackendConfig {
  MovieBackendConfig({required Uri baseUrl, required this.remoteFamilyId,
    required this.bearerToken, bool allowInsecureLoopback = false})
      : baseUrl = _base(baseUrl, allowInsecureLoopback: allowInsecureLoopback) {
    if (!RegExp(r'^[a-zA-Z0-9-]{1,80}$').hasMatch(remoteFamilyId) || bearerToken.isEmpty) {
      throw const ExternalServiceException('电影', ServiceFailure.notConfigured);
    }
  }
  final Uri baseUrl;
  final String remoteFamilyId, bearerToken;
}

class MovieCatalogueClient {
  MovieCatalogueClient({required this.loadConfig, required http.Client client,
    Duration timeout = const Duration(seconds: 15)})
      : _http = _Transport(client, '电影', timeout);
  final Future<MovieBackendConfig?> Function() loadConfig;
  final _Transport _http;
  static final _poster = RegExp(r'^/[a-zA-Z0-9_-]+\.(jpg|jpeg|png|webp)$', caseSensitive: false);

  Future<({MovieBackendConfig config, Uri route})> _configured(String tail) async {
    final config = await _configuration(loadConfig, '电影');
    if (config == null) throw const ExternalServiceException('电影', ServiceFailure.notConfigured);
    return (config: config, route: _route(config.baseUrl,
        'api/v1/families/${config.remoteFamilyId}/plugins/movie/discover$tail'));
  }

  http.Request _get(Uri uri, MovieBackendConfig config) => http.Request('GET', uri)
    ..headers['Authorization'] = 'Bearer ${config.bearerToken}'
    ..headers['Accept'] = 'application/json';

  Future<List<dynamic>> _list(http.Request request) async {
    final body = await _http.json(request);
    if (body is! Map || body['success'] != true || body['data'] is! List) {
      throw const ExternalServiceException('电影', ServiceFailure.invalidResponse,
          requestMayHaveBeenSent: true);
    }
    return body['data'] as List;
  }

  Future<List<Map<String, dynamic>>> genres() async {
    final c = await _configured('/genres');
    final rows = await _list(_get(c.route, c.config));
    return [for (final row in rows)
      if (row is Map && row['id'] is int && row['name'] is String)
        {'id': row['id'], 'name': row['name']}];
  }

  Future<List<Map<String, dynamic>>> discover({List<int> genreIds = const [],
    String sort = 'popular', int page = 1, Set<int> locallyAddedTmdbIds = const {}}) async {
    if (!['popular', 'rating', 'newest'].contains(sort) || page < 1 || page > 500 ||
        genreIds.any((id) => id <= 0)) {
      throw const ExternalServiceException('电影', ServiceFailure.invalidInput);
    }
    final c = await _configured('');
    final uri = c.route.replace(queryParameters: {
      if (genreIds.isNotEmpty) 'genres': genreIds.toSet().join(','),
      'sort': sort, 'page': '$page',
    });
    final rows = await _list(_get(uri, c.config));
    final output = <Map<String, dynamic>>[];
    for (final row in rows) {
      if (row is! Map || row['tmdb_id'] is! int || row['title'] is! String) continue;
      String? poster;
      final supplied = row['poster_url'];
      if (supplied is String) {
        final candidate = Uri.tryParse(supplied);
        if (candidate != null && !candidate.hasAuthority && !candidate.hasFragment &&
            candidate.path == c.route.path + '/poster' && candidate.queryParameters.length == 1 &&
            _poster.hasMatch(candidate.queryParameters['path'] ?? '')) poster = supplied;
      }
      output.add({
        'tmdb_id': row['tmdb_id'], 'title': row['title'],
        'overview': row['overview'] is String ? row['overview'] : null,
        'release_date': row['release_date'] is String ? row['release_date'] : null,
        'tmdb_rating': row['tmdb_rating'] is num ? row['tmdb_rating'] : null,
        'poster_url': poster,
        // 后端旧片单不能决定本地片单状态，也不回传本地集合。
        'already_added': locallyAddedTmdbIds.contains(row['tmdb_id']),
      });
    }
    return output;
  }

  Future<GeneratedImage> poster(String posterPath) async {
    if (!_poster.hasMatch(posterPath)) throw const ExternalServiceException('电影', ServiceFailure.invalidInput);
    final c = await _configured('/poster');
    final result = await _http.send(_get(c.route.replace(queryParameters: {'path': posterPath}), c.config), 20 * 1024 * 1024);
    return GeneratedImage.validated(result.bytes, service: '电影');
  }
}

class AuthorizedLocation {
  const AuthorizedLocation(this.latitude, this.longitude);
  final double latitude, longitude;
}

/// 沿用仓库既有 QWeather 协议形状；不写旧后端 plant/settings 坐标。
class WeatherServiceConfig {
  WeatherServiceConfig({required Uri baseUrl, required this.apiKey,
    bool allowInsecureLoopback = false})
      : baseUrl = _base(baseUrl, allowInsecureLoopback: allowInsecureLoopback);
  final Uri baseUrl;
  final String apiKey;
}

class WeatherClient {
  WeatherClient({required this.loadConfig, required this.locateWithPermission,
    required http.Client client, Duration timeout = const Duration(seconds: 12)})
      : _http = _Transport(client, '天气', timeout);
  final Future<WeatherServiceConfig?> Function() loadConfig;
  /// 必须由设备权限流程提供；拒绝/未授权返回 null，不用持久化的旧云坐标代替。
  final Future<AuthorizedLocation?> Function() locateWithPermission;
  final _Transport _http;
  Future<Map<String, dynamic>> current() async {
    final config = await _configuration(loadConfig, '天气');
    if (config == null || config.apiKey.isEmpty) throw const ExternalServiceException('天气', ServiceFailure.notConfigured);
    AuthorizedLocation? location;
    try { location = await locateWithPermission(); } catch (_) { throw const ExternalServiceException('天气', ServiceFailure.locationDenied); }
    if (location == null) throw const ExternalServiceException('天气', ServiceFailure.locationDenied);
    if (!location.latitude.isFinite || !location.longitude.isFinite ||
        location.latitude.abs() > 90 || location.longitude.abs() > 180) {
      throw const ExternalServiceException('天气', ServiceFailure.invalidInput);
    }
    // 天气不需要高度/速度/朝向/身份；将位置降低到约公里精度。
    final lat = location.latitude.toStringAsFixed(2), lon = location.longitude.toStringAsFixed(2);
    final query = {'location': '$lon,$lat', 'key': config.apiKey};
    final now = await _http.json(http.Request('GET', _route(config.baseUrl, 'weather/now', query)));
    if (now is! Map || now['code'] != '200' || now['now'] is! Map) {
      throw const ExternalServiceException('天气', ServiceFailure.invalidResponse, requestMayHaveBeenSent: true);
    }
    final n = now['now'] as Map;
    double? number(dynamic input) { final value = double.tryParse('$input'); return value?.isFinite == true ? value : null; }
    String? text(dynamic input) => input is String && input.length <= 200 ? input : null;
    if (number(n['temp']) == null && text(n['text']) == null) throw const ExternalServiceException('天气', ServiceFailure.invalidResponse, requestMayHaveBeenSent: true);
    final output = <String, dynamic>{'available': true, 'latitude': double.parse(lat), 'longitude': double.parse(lon),
      'temp_c': number(n['temp']), 'feels_like_c': number(n['feelsLike']), 'condition': text(n['text']),
      'icon': text(n['icon']), 'humidity_pct': number(n['humidity'])?.toInt(), 'precip_mm': number(n['precip']),
      'wind_dir': text(n['windDir']), 'wind_scale': text(n['windScale']), 'wind_speed_kmh': number(n['windSpeed']),
      'wind_deg': number(n['wind360']), 'pressure_hpa': number(n['pressure']), 'visibility_km': number(n['vis']),
      'cloud_pct': number(n['cloud'])?.toInt(), 'dew_point_c': number(n['dew']),
      'observed_at': text(now['updateTime']) ?? text(n['obsTime']), 'uv_index': null};
    try {
      final uv = await _http.json(http.Request('GET', _route(config.baseUrl, 'indices/1d', {...query, 'type': '5'})));
      if (uv is Map && uv['code'] == '200' && uv['daily'] is List && (uv['daily'] as List).isNotEmpty) {
        final first = (uv['daily'] as List).first;
        if (first is Map) output['uv_index'] = number(first['level']);
      }
    } on ExternalServiceException { /* 可选 UV 失败不抹掉已收到的天气。 */ }
    return output;
  }
}

/// 调用者应先用设备图像编码器重编码供模型使用的副本，原照继续本地保留。
/// 在远程边界拒绝 EXIF/XMP/文本元数据，避免无意提交 GPS 等非必要信息。
class PreparedModelImage {
  PreparedModelImage(List<int> data) : bytes = Uint8List.fromList(data).asUnmodifiableView() {
    contentType = _imageType(bytes);
    if (bytes.length > 20 * 1024 * 1024 || !_metadataFree(bytes, contentType)) {
      throw const ExternalServiceException('图片生成', ServiceFailure.invalidInput);
    }
  }
  final Uint8List bytes;
  late final String contentType;
}

class ImageModelConfig {
  ImageModelConfig({required Uri baseUrl, required this.apiKey, required this.model,
    this.enabled = true, this.retentionNotice = '', Iterable<Uri> resultOrigins = const [],
    bool allowInsecureLoopback = false})
      : baseUrl = _base(baseUrl, allowInsecureLoopback: allowInsecureLoopback),
        resultOrigins = Set.unmodifiable({for (final uri in resultOrigins) _origin(_base(uri, allowInsecureLoopback: allowInsecureLoopback))});
  final Uri baseUrl;
  final String apiKey, model, retentionNotice;
  final bool enabled;
  final Set<Uri> resultOrigins;
}

class ImageGenerationConsent {
  const ImageGenerationConsent({required this.endpoint, required this.retentionNotice,
    required this.allowSourceUpload, required this.providerPolicyReviewed});
  final Uri endpoint;
  final String retentionNotice;
  final bool allowSourceUpload, providerPolicyReviewed;
}

class GeneratedImage {
  GeneratedImage.validated(List<int> data, {String service = '图片生成'}) : bytes = Uint8List.fromList(data).asUnmodifiableView() {
    if (bytes.length > 20 * 1024 * 1024) throw ExternalServiceException(service, ServiceFailure.invalidResponse);
    try { contentType = _imageType(bytes); } catch (_) { throw ExternalServiceException(service, ServiceFailure.invalidResponse); }
  }
  final Uint8List bytes;
  late final String contentType;
}

class ConfiguredImageClient {
  ConfiguredImageClient({required this.loadConfig, required http.Client client,
    Duration timeout = const Duration(minutes: 3)})
      : _http = _Transport(client, '图片生成', timeout);
  final Future<ImageModelConfig?> Function() loadConfig;
  final _Transport _http;
  Future<GeneratedImage> generate({required PreparedModelImage image,
    required String prompt, required ImageGenerationConsent consent}) async {
    final config = await _configuration(loadConfig, '图片生成');
    if (config == null || !config.enabled || config.apiKey.isEmpty || config.model.trim().isEmpty) {
      throw const ExternalServiceException('图片生成', ServiceFailure.notConfigured);
    }
    if (!consent.allowSourceUpload || !consent.providerPolicyReviewed ||
        consent.endpoint != config.baseUrl || config.retentionNotice.trim().isEmpty ||
        consent.retentionNotice != config.retentionNotice) {
      throw const ExternalServiceException('图片生成', ServiceFailure.consentRequired);
    }
    if (prompt.trim().isEmpty || prompt.length > 12000) throw const ExternalServiceException('图片生成', ServiceFailure.invalidInput);
    final request = http.Request('POST', _route(config.baseUrl, 'images/generations'))
      ..headers['Authorization'] = 'Bearer ${config.apiKey}'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'model': config.model, 'prompt': prompt, 'size': '2048x2048',
        'response_format': 'b64_json', 'watermark': false,
        'image': 'data:${image.contentType};base64,${base64Encode(image.bytes)}'});
    final body = await _http.json(request, limit: 28 * 1024 * 1024);
    if (body is! Map || body['data'] is! List || (body['data'] as List).isEmpty || (body['data'] as List).first is! Map) {
      throw const ExternalServiceException('图片生成', ServiceFailure.invalidResponse, requestMayHaveBeenSent: true);
    }
    final first = (body['data'] as List).first as Map;
    final base64 = first['b64_json'];
    if (base64 is String && base64.isNotEmpty) {
      try { return GeneratedImage.validated(base64Decode(base64)); }
      catch (_) { throw const ExternalServiceException('图片生成', ServiceFailure.invalidResponse, requestMayHaveBeenSent: true); }
    }
    final uri = first['url'] is String ? Uri.tryParse(first['url'] as String) : null;
    if (uri == null || uri.userInfo.isNotEmpty || uri.hasFragment ||
        !{_origin(config.baseUrl), ...config.resultOrigins}.contains(_origin(uri))) {
      throw const ExternalServiceException('图片生成', ServiceFailure.invalidResponse, requestMayHaveBeenSent: true);
    }
    // 认证只交给配置模型端点，不转交给结果 CDN，不跟随重定向。
    final download = await _http.send(http.Request('GET', uri), 20 * 1024 * 1024);
    return GeneratedImage.validated(download.bytes);
  }
}

String _imageType(Uint8List data) {
  if (data.length >= 4 && data[0] == 0xff && data[1] == 0xd8 && data[data.length - 2] == 0xff && data.last == 0xd9) return 'image/jpeg';
  if (data.length >= 8 && const [137,80,78,71,13,10,26,10].indexed.every((e) => data[e.$1] == e.$2)) return 'image/png';
  if (data.length >= 12 && ascii.decode(data.sublist(0,4), allowInvalid: true) == 'RIFF' && ascii.decode(data.sublist(8,12), allowInvalid: true) == 'WEBP') return 'image/webp';
  throw const ExternalServiceException('图片生成', ServiceFailure.invalidInput);
}

bool _metadataFree(Uint8List bytes, String type) {
  if (type == 'image/jpeg') {
    // 多扫描 JPEG 可在 SOS 后还有 APP 段；对全文件保守拒绝这些元数据标记。
    for (var i = 2; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0xff && [0xe1, 0xed, 0xfe].contains(bytes[i + 1])) return false;
    }
    var offset = 2;
    while (offset + 1 < bytes.length) {
      if (bytes[offset] != 0xff) return false;
      final marker = bytes[offset + 1];
      if (marker == 0xda || marker == 0xd9) return true;
      if ([0xe1, 0xed, 0xfe].contains(marker) || offset + 4 > bytes.length) return false;
      final length = (bytes[offset+2] << 8) | bytes[offset+3];
      if (length < 2 || offset + length + 2 > bytes.length) return false;
      offset += length + 2;
    }
    return false;
  }
  final data = ByteData.sublistView(bytes);
  var offset = type == 'image/png' ? 8 : 12;
  while (offset + 8 <= bytes.length) {
    final png = type == 'image/png';
    final length = data.getUint32(offset, png ? Endian.big : Endian.little);
    final nameStart = png ? offset + 4 : offset;
    final name = ascii.decode(bytes.sublist(nameStart, nameStart + 4), allowInvalid: true);
    final size = png ? length + 12 : data.getUint32(offset + 4, Endian.little) + 8;
    if (['eXIf','tEXt','iTXt','zTXt','EXIF','XMP '].contains(name) || size < 8 || offset + size > bytes.length) return false;
    if (png && name == 'IEND') return offset + size == bytes.length;
    offset += size + (png ? 0 : size % 2);
  }
  return type == 'image/webp' && offset == bytes.length;
}
