/// 后端接入配置。
///
/// 默认指向已部署的服务器；可在构建期用 --dart-define 覆盖，例如：
///   flutter run --dart-define=WO_API_BASE_URL=http://10.0.2.2:8000
///   flutter run --dart-define=WO_USER_ID=019000a0-1100-7000-8000-000000000002
class ApiConfig {
  ApiConfig._();

  /// API 根地址（不含 /api/v1 前缀）。
  static const baseUrl = String.fromEnvironment(
    'WO_API_BASE_URL',
    defaultValue: 'https://122.51.81.235',
  );

  /// 开发期强制身份覆盖：后端用 X-User-Id 头识别当前用户（P5 接真实 JWT 前的
  /// 临时方案）。默认空 = 走手机号登录拿身份；用 `--dart-define=WO_USER_ID=<uuid>`
  /// 可跳过登录直接以某个种子用户身份调试。
  static const devUserId =
      String.fromEnvironment('WO_USER_ID', defaultValue: '');

  /// 所有业务接口的统一前缀。
  static const apiPrefix = '/api/v1';
}
