import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_config.dart';

/// 后端返回的业务错误（信封 success=false 时抛出）。
class ApiException implements Exception {
  ApiException(this.code, this.message, {this.statusCode, this.details});

  final String code;
  final String message;
  final int? statusCode;
  final Map<String, dynamic>? details;

  @override
  String toString() => 'ApiException($code): $message';
}

/// 网络层无法连接 / 超时 / 解析失败时抛出。
class NetworkException implements Exception {
  NetworkException(this.message);
  final String message;

  @override
  String toString() => 'NetworkException: $message';
}

/// 轻量 HTTP 客户端：负责拼地址、带鉴权头、拆响应信封、抛错。
///
/// 业务层只拿到 `data` 字段（已解码的 Map / List）；信封里的 success/error
/// 由本类统一处理，不让每个页面重复写。
class ApiClient {
  ApiClient({
    http.Client? httpClient,
    String? baseUrl,
    String? userId,
  })  : _http = httpClient ?? http.Client(),
        _baseUrl = baseUrl ?? ApiConfig.baseUrl,
        userId = userId ?? ApiConfig.devUserId;

  final http.Client _http;
  final String _baseUrl;

  /// 当前请求身份（X-User-Id）。多账号流程里可切换。
  String userId;

  static const _timeout = Duration(seconds: 15);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        // Only identify when logged in; /auth/login itself is public.
        if (userId.isNotEmpty) 'X-User-Id': userId,
      };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$_baseUrl${ApiConfig.apiPrefix}$normalized').replace(
      queryParameters: query?.map((k, v) => MapEntry(k, '$v')),
    );
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => _http.get(_uri(path, query), headers: _headers));

  Future<dynamic> post(String path, {Object? body}) => _send(
        () => _http.post(_uri(path), headers: _headers, body: _encode(body)),
      );

  Future<dynamic> patch(String path, {Object? body}) => _send(
        () => _http.patch(_uri(path), headers: _headers, body: _encode(body)),
      );

  Future<dynamic> put(String path, {Object? body}) => _send(
        () => _http.put(_uri(path), headers: _headers, body: _encode(body)),
      );

  Future<dynamic> delete(String path, {Object? body}) => _send(
        () => _http.delete(_uri(path), headers: _headers, body: _encode(body)),
      );

  String? _encode(Object? body) => body == null ? null : jsonEncode(body);

  /// 执行请求 + 拆信封。成功返回 `data`，失败抛 [ApiException] / [NetworkException]。
  Future<dynamic> _send(Future<http.Response> Function() run) async {
    final http.Response res;
    try {
      res = await run().timeout(_timeout);
    } on TimeoutException {
      throw NetworkException('请求超时，请检查网络');
    } catch (e) {
      throw NetworkException('无法连接服务器：$e');
    }

    Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw NetworkException('服务器返回了无法解析的内容（${res.statusCode}）');
    }

    final success = envelope['success'] == true;
    if (!success) {
      final err = envelope['error'] as Map<String, dynamic>?;
      throw ApiException(
        (err?['code'] as String?) ?? 'UNKNOWN',
        (err?['message'] as String?) ?? '请求失败',
        statusCode: res.statusCode,
        details: err?['details'] as Map<String, dynamic>?,
      );
    }
    return envelope['data'];
  }

  void close() => _http.close();
}
