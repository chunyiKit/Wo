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
    String? authToken,
  })  : _http = httpClient ?? http.Client(),
        _baseUrl = baseUrl ?? ApiConfig.baseUrl,
        userId = userId ?? ApiConfig.devUserId,
        authToken = authToken ?? '';

  final http.Client _http;
  final String _baseUrl;

  /// 登录签发的会话令牌（Bearer）。登录后设置，登出清空。
  String authToken;

  /// 仅 dev：无会话令牌时回退用的 X-User-Id 身份（生产后端已关闭该通道）。
  String userId;

  static const _timeout = Duration(seconds: 15);

  /// 拼接图片等原始资源的完整地址用（相对路径已含 /api/v1 前缀，故这里只给 host）。
  String get baseUrl => _baseUrl;

  /// 认证头：优先会话令牌(Bearer)；没有则回退 X-User-Id(仅 dev 调试通道)。
  /// 都没有则不带（如 /auth/login 等公开接口）。
  Map<String, String> get _authHeaders {
    if (authToken.isNotEmpty) return {'Authorization': 'Bearer $authToken'};
    if (userId.isNotEmpty) return {'X-User-Id': userId};
    return const {};
  }

  /// 加载受鉴权保护的资源（如菜谱封面原图、电影海报）时要带的头。
  Map<String, String> get imageHeaders => _authHeaders;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        ..._authHeaders,
      };

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$_baseUrl${ApiConfig.apiPrefix}$normalized').replace(
      queryParameters: query?.map((k, v) => MapEntry(k, '$v')),
    );
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => _http.get(_uri(path, query), headers: _headers));

  /// 同 [get]，但额外带回信封里的 `meta`（分页元数据）。返回 (data, meta)：
  /// 普通接口 meta 为 null，分页接口里含 total / cursor / limit。
  Future<({dynamic data, Map<String, dynamic>? meta})> getWithMeta(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final envelope = await _sendEnvelope(
        () => _http.get(_uri(path, query), headers: _headers));
    return (
      data: envelope['data'],
      meta: envelope['meta'] as Map<String, dynamic>?
    );
  }

  Future<dynamic> post(String path, {Object? body, Duration? timeout}) => _send(
        () => _http.post(_uri(path), headers: _headers, body: _encode(body)),
        timeout: timeout,
      );

  Future<dynamic> patch(String path, {Object? body}) => _send(
        () => _http.patch(_uri(path), headers: _headers, body: _encode(body)),
      );

  Future<dynamic> put(String path, {Object? body}) => _send(
        () => _http.put(_uri(path), headers: _headers, body: _encode(body)),
      );

  Future<dynamic> delete(String path,
          {Object? body, Map<String, dynamic>? query}) =>
      _send(
        () => _http.delete(
          _uri(path, query),
          headers: _headers,
          body: _encode(body),
        ),
      );

  /// 上传单个文件（multipart/form-data）。不声明文件 content-type——后端
  /// 自行探测真实格式，不信任客户端声明的类型。[fields] 是随文件一起带上的
  /// 额外表单字段（如视频时长 duration_ms）。
  Future<dynamic> uploadFile(
    String path, {
    required List<int> bytes,
    required String filename,
    String field = 'file',
    Map<String, String>? fields,
  }) =>
      _send(() async {
        final req = http.MultipartRequest('POST', _uri(path));
        req.headers.addAll(_authHeaders);
        req.headers['Accept'] = 'application/json';
        if (fields != null) req.fields.addAll(fields);
        req.files.add(
          http.MultipartFile.fromBytes(field, bytes, filename: filename),
        );
        return http.Response.fromStream(await req.send());
      });

  /// 上传多个文件（multipart/form-data，同一 [field] 多个部分）。后端用
  /// `list[UploadFile]` 接收。[filesData] 每项为 (bytes, filename)。
  Future<dynamic> uploadFiles(
    String path, {
    required List<(List<int>, String)> filesData,
    String field = 'files',
    Map<String, String>? fields,
  }) =>
      _send(() async {
        final req = http.MultipartRequest('POST', _uri(path));
        req.headers.addAll(_authHeaders);
        req.headers['Accept'] = 'application/json';
        if (fields != null) req.fields.addAll(fields);
        for (final (bytes, filename) in filesData) {
          req.files.add(
            http.MultipartFile.fromBytes(field, bytes, filename: filename),
          );
        }
        return http.Response.fromStream(await req.send());
      });

  String? _encode(Object? body) => body == null ? null : jsonEncode(body);

  /// 执行请求 + 拆信封。成功返回 `data`，失败抛 [ApiException] / [NetworkException]。
  Future<dynamic> _send(
    Future<http.Response> Function() run, {
    Duration? timeout,
  }) async =>
      (await _sendEnvelope(run, timeout: timeout))['data'];

  /// 执行请求并返回完整信封（含 data / meta）。成功返回整个 map，失败抛
  /// [ApiException] / [NetworkException]。[_send] 与 [getWithMeta] 共用此逻辑，
  /// 区别只在前者取 `data`、后者还要 `meta`。
  Future<Map<String, dynamic>> _sendEnvelope(
    Future<http.Response> Function() run, {
    Duration? timeout,
  }) async {
    final http.Response res;
    try {
      res = await run().timeout(timeout ?? _timeout);
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
    return envelope;
  }

  void close() => _http.close();
}
