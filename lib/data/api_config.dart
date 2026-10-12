/// 后端接入配置。
///
/// 地址由本地配置文件在构建期注入，例如：
///   bash tool/flutter.sh run
///   flutter run --dart-define-from-file=config/app.local.json
///   flutter run --dart-define=WO_USER_ID=019000a0-1100-7000-8000-000000000002
class ApiConfig {
  ApiConfig._();

  static const _configuredBaseUrl = String.fromEnvironment(
    'WO_API_BASE_URL',
  );

  /// API 根地址（不含 /api/v1 前缀），统一去掉末尾斜杠。
  static String get baseUrl =>
      _configuredBaseUrl.replaceFirst(RegExp(r'/+$'), '');

  /// 启动时检查配置，避免漏传地址后发出无效请求。
  static void validate() {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw StateError(
        '请在 config/app.local.json 中配置有效的 WO_API_BASE_URL，'
        '并使用 bash tool/flutter.sh run/build 注入配置。',
      );
    }
  }

  /// 开发期强制身份覆盖：后端用 X-User-Id 头识别当前用户（P5 接真实 JWT 前的
  /// 临时方案）。默认空 = 走手机号登录拿身份；用 `--dart-define=WO_USER_ID=<uuid>`
  /// 可跳过登录直接以某个种子用户身份调试。
  static const devUserId =
      String.fromEnvironment('WO_USER_ID', defaultValue: '');

  /// 所有业务接口的统一前缀。
  static const apiPrefix = '/api/v1';

  /// 极光 AppKey。这是**公开**标识（会随 APK 一起分发，也写在 Android manifest
  /// 占位符里），非机密；真正的 MasterSecret 只在后端。Dart 侧的 setup() 主要给
  /// iOS 用，Android 由 manifest meta-data 驱动，两边保持一致即可。
  static const jpushAppKey = 'c7b049b2dae09a723655dc8e';

  /// 极光渠道标识，与 Android manifest 占位符 JPUSH_CHANNEL 对齐。
  static const jpushChannel = 'default_developer';
}
