import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// 全局 HTTP 覆盖：让 App 信任我们自己的私有 CA（assets/certs/wo_ca.crt）。
///
/// 服务器用裸 IP + 自签证书,公共根证书无法验证。这里把内置 CA 装进一个
/// **不含系统根证书**（`withTrustedRoots: false`）的 [SecurityContext],于是
/// App 只信任这一张证书 —— 等价于证书绑定(cert pinning),比信任公共 CA 更
/// 抗中间人攻击。
///
/// 装上后,所有走 dart:io 的出站连接(package:http、Image.network 等)都会用
/// 这个信任链,无需逐处改代码。明文 http(如本地 10.0.2.2 调试)不受影响。
class WoHttpOverrides extends HttpOverrides {
  WoHttpOverrides._(this._context);

  final SecurityContext _context;

  /// 资源里 CA 证书的路径(见 pubspec.yaml 的 assets 段)。
  static const _caAssetPath = 'assets/certs/wo_ca.crt';

  /// 读取内置 CA 并构造覆盖实例。必须在 runApp 之前 await。
  static Future<WoHttpOverrides> load() async {
    final caBytes = await rootBundle.load(_caAssetPath);
    final context = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(caBytes.buffer.asUint8List());
    return WoHttpOverrides._(context);
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context ?? _context);
}
