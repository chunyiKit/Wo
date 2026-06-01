import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// 全局 HTTP 覆盖：让 App 同时信任「自签 CA + 系统公共根证书」。
///
/// 历史:最早版本用 `withTrustedRoots: false` 锁死成只信自签 CA(因为后端是裸 IP
/// + 自签证书),抗 MITM 强一档。但随着我们引入腾讯云 COS——APK 分发、回忆图片
/// 都会被后端 302 重定向到 `*.myqcloud.com`(公共 CA 签发)——pin-only 这条路就
/// 走不通了:`CachedNetworkImage` / `flutter_cache_manager` 走的都是默认 HTTP
/// 客户端,跟着重定向到 COS 时 TLS 握手会失败,新上传的图无法浏览。
///
/// 改成 `withTrustedRoots: true` 同时把自签 CA 装进去后,两边都覆盖:
/// - 后端 `122.51.81.235` 的自签证书 → 走 pin 的 CA 链验证
/// - COS 等公共 CA 签发的证书 → 走系统根验证
///
/// 安全 trade-off:之前 pin-only 能挡住「公共 CA 给我们的 IP 误签证书后 MITM」
/// 这种细节攻击;放开后这一档防护没了。考虑到 COS 是业务必经路径,且公共 CA 给
/// 裸 IP 签证书的门槛极高,这个交换是值得的。
class WoHttpOverrides extends HttpOverrides {
  WoHttpOverrides._(this._context, this._caBytes);

  final SecurityContext _context;
  final List<int> _caBytes;

  static WoHttpOverrides? _instance;

  /// 资源里 CA 证书的路径(见 pubspec.yaml 的 assets 段)。
  static const _caAssetPath = 'assets/certs/wo_ca.crt';

  /// 读取内置 CA 并构造覆盖实例。必须在 runApp 之前 await。
  static Future<WoHttpOverrides> load() async {
    final caData = await rootBundle.load(_caAssetPath);
    final caBytes = caData.buffer.asUint8List();
    // withTrustedRoots: true → 同时信任系统公共根;再叠上自签 CA。
    final context = SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificatesBytes(caBytes);
    final overrides = WoHttpOverrides._(context, caBytes);
    _instance = overrides;
    return overrides;
  }

  /// 历史上提供过「inclusive」context 用于跨主机下载;放开全局信任后它和默认
  /// context 行为完全一致,保留只是为了不破坏老调用点(应用内更新 / 回忆保存到
  /// 相册等)的签名。
  static SecurityContext inclusiveContext() {
    final inst = _instance;
    if (inst == null) {
      throw StateError(
        'WoHttpOverrides.load() must be awaited before inclusiveContext()',
      );
    }
    return SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificatesBytes(inst._caBytes);
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context ?? _context);
}
