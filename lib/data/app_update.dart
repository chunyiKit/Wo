import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api_client.dart';
import 'wo_http_overrides.dart';

/// 后端 `/app/version` 返回的最新发布信息。
class AppRelease {
  const AppRelease({
    required this.versionName,
    required this.versionCode,
    required this.notes,
    required this.size,
    required this.sha256,
    required this.downloadUrl,
  });

  /// 展示用版本号（pubspec 的 x.y.z）。
  final String versionName;

  /// Android versionCode（pubspec `+N`），单调递增，用于比较是否有新版。
  final int versionCode;

  /// 更新说明，可为空。
  final String notes;

  /// APK 字节数。
  final int size;

  /// APK 的 sha256（保留字段，当前下载未强制校验）。
  final String sha256;

  /// 下载地址（含 /api/v1 前缀的 host 相对路径），客户端拼上 baseUrl 用。
  final String downloadUrl;

  factory AppRelease.fromJson(Map<String, dynamic> j) => AppRelease(
        versionName: j['version_name'] as String? ?? '',
        versionCode: (j['version_code'] as num?)?.toInt() ?? 0,
        notes: j['notes'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        sha256: j['sha256'] as String? ?? '',
        downloadUrl: j['download_url'] as String? ?? '',
      );
}

/// 应用内更新：读当前版本、下载 APK、调起系统安装器。
///
/// 下载 APK 时使用 [WoHttpOverrides.inclusiveContext] 构造的 [HttpClient],
/// 它同时信任**系统公共根证书 + 自签 CA**。这样无论 `download_url` 指向后端
/// 自签 IP、腾讯云 COS 公共域名,还是从后端 302 跳到 COS,整条链路都能完成
/// TLS 握手。其它 API 请求继续走全局 pin-only 信任链,不受影响。
///
/// 关于「不需要重新登录」：APK 同包名、同签名的覆盖安装，Android 会保留应用
/// 数据（含 SharedPreferences 里的登录 token），所以更新后自动保持登录态——
/// 本流程不触碰任何登录数据，天然满足要求。
class AppUpdateService {
  AppUpdateService({required this.baseUrl});

  /// 后端 host（不含 /api/v1）。
  final String baseUrl;

  /// 读取当前运行的版本信息。
  Future<PackageInfo> currentInfo() => PackageInfo.fromPlatform();

  /// 拼出 APK 的完整下载地址。
  String _absoluteUrl(String pathOrUrl) {
    if (pathOrUrl.startsWith('http')) return pathOrUrl;
    return '$baseUrl$pathOrUrl';
  }

  /// 下载 APK 到应用私有目录，[onProgress] 回传 0~1 进度（拿不到总长则回传 null）。
  /// 返回落盘后的文件。
  Future<File> downloadApk(
    AppRelease release, {
    void Function(double? progress)? onProgress,
  }) async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/wo-${release.versionCode}.apk');

    // 已经完整下载过（大小吻合）就直接复用，避免取消安装后重下。
    if (release.size > 0 &&
        await file.exists() &&
        await file.length() == release.size) {
      onProgress?.call(1.0);
      return file;
    }

    final client = HttpClient(context: WoHttpOverrides.inclusiveContext());
    try {
      final req = await client.getUrl(Uri.parse(_absoluteUrl(release.downloadUrl)));
      final resp = await req.close();
      if (resp.statusCode != HttpStatus.ok) {
        throw HttpException('下载失败（${resp.statusCode}）');
      }

      final total = resp.contentLength > 0 ? resp.contentLength : release.size;
      var received = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in resp) {
          received += chunk.length;
          sink.add(chunk);
          if (onProgress != null) {
            onProgress(total > 0 ? (received / total).clamp(0.0, 1.0) : null);
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return file;
    } catch (_) {
      // 下载出错则清掉半截文件，避免下次误用。
      if (await file.exists()) {
        await file.delete();
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  /// 调起系统安装器安装 APK。返回 false 表示缺少「安装未知应用」权限（已引导申请）。
  Future<bool> install(File apk) async {
    final status = await Permission.requestInstallPackages.request();
    if (!status.isGranted) return false;
    await OpenFilex.open(
      apk.path,
      type: 'application/vnd.android.package-archive',
    );
    return true;
  }
}

/// 更新流程的阶段。
enum AppUpdatePhase { idle, checking, upToDate, available, downloading }

/// 应用内更新的全局状态机。
///
/// 关键点：它挂在 [WoSession]（与 App 同生命周期）上，而不是「关于」页的 State 里。
/// 因此用户在下载过程中离开「关于」页，下载不会中断；重新进入页面时能看到当前
/// 进度，而不会重新开始下载。
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required AppUpdateService service,
    required Future<AppRelease?> Function() fetchLatest,
  })  : _service = service,
        _fetchLatest = fetchLatest;

  final AppUpdateService _service;
  final Future<AppRelease?> Function() _fetchLatest;

  AppUpdatePhase _phase = AppUpdatePhase.idle;
  AppRelease? _release;
  double? _progress;
  String? _message;
  int _currentBuild = 0;
  String _currentVersionName = '';
  bool _disposed = false;

  AppUpdatePhase get phase => _phase;
  AppRelease? get release => _release;

  /// 下载进度 0~1；null 表示进行中但总长未知。
  double? get progress => _progress;

  /// 失败原因 / 权限提示，供页面展示。
  String? get message => _message;

  int get currentBuild => _currentBuild;
  String get currentVersionName => _currentVersionName;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  /// 读取当前运行版本（「关于」页头部展示用）。已读过则跳过。
  Future<void> loadCurrentInfo() async {
    if (_currentVersionName.isNotEmpty) return;
    try {
      final info = await _service.currentInfo();
      _currentVersionName = info.version;
      _currentBuild = int.tryParse(info.buildNumber) ?? 0;
      _emit();
    } catch (_) {
      // 读不到版本不致命，头部回退到占位。
    }
  }

  /// 检查更新。下载进行中不打断；正在检查时忽略重复触发。
  Future<void> check() async {
    if (_phase == AppUpdatePhase.checking ||
        _phase == AppUpdatePhase.downloading) {
      return;
    }
    _phase = AppUpdatePhase.checking;
    _message = null;
    _emit();
    try {
      final info = await _service.currentInfo();
      _currentVersionName = info.version;
      _currentBuild = int.tryParse(info.buildNumber) ?? 0;
      _release = await _fetchLatest();
      final hasUpdate =
          _release != null && _release!.versionCode > _currentBuild;
      _phase = hasUpdate ? AppUpdatePhase.available : AppUpdatePhase.upToDate;
    } catch (e) {
      _message = _humanize(e);
      _phase = (_release != null && _release!.versionCode > _currentBuild)
          ? AppUpdatePhase.available
          : AppUpdatePhase.idle;
    }
    _emit();
  }

  /// 下载并安装。下载中重复调用直接忽略（这正是「重进页面不重复下载」的保证）。
  Future<void> downloadAndInstall() async {
    final r = _release;
    if (r == null || _phase == AppUpdatePhase.downloading) return;
    _phase = AppUpdatePhase.downloading;
    _progress = null;
    _message = null;
    _emit();
    try {
      final file = await _service.downloadApk(
        r,
        onProgress: (p) {
          _progress = p;
          _emit();
        },
      );
      final granted = await _service.install(file);
      _message = granted ? null : '需要授权「安装未知应用」才能完成更新';
    } catch (e) {
      _message = _humanize(e);
    } finally {
      // 回到「可更新」，便于取消安装后重试（APK 已在本地，秒级完成）。
      _phase = AppUpdatePhase.available;
      _progress = null;
      _emit();
    }
  }

  String _humanize(Object e) => switch (e) {
        ApiException ex => ex.message,
        NetworkException ex => ex.message,
        HttpException ex => ex.message,
        _ => '操作失败，请稍后再试',
      };

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
