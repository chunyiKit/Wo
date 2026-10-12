import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'api_config.dart';
import 'app_update.dart';
import 'memory_cache.dart';
import 'models.dart';
import 'push_service.dart';
import 'wo_api.dart';

typedef AuthSnapshot = ({int generation, String? token});

/// 持久化服务端可撤销的 Bearer 会话，并管理首屏数据。
class WoSession extends ChangeNotifier {
  WoSession({WoApi? api, this.push}) : api = api ?? WoApi(ApiClient()) {
    this.api.onSessionInvalid = clearAuth;
  }

  static const _kToken = 'wo.token';
  static const _kThemeMode = 'wo.themeMode';

  final WoApi api;

  /// 应用内更新的全局状态机。挂在会话上（与 App 同生命周期），使「关于」页的
  /// 下载进度在离开/重进页面时不丢失、不重复下载。
  late final AppUpdateController appUpdate = AppUpdateController(
    service: AppUpdateService(baseUrl: api.baseUrl),
    fetchLatest: api.latestRelease,
  );

  /// 外观主题：浅色 / 深色（默认）/ 跟随系统。本地持久化，启动时由
  /// [loadThemeMode] 读出。用 ValueNotifier 单独承载，避免主题切换牵动其他 UI。
  final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier<ThemeMode>(ThemeMode.dark);

  /// 可选的推送服务。注入后会在登录/启动时上报本机 registration id、登出时注销。
  /// 测试与非移动端不注入（为 null），相关逻辑自动跳过。
  final PushService? push;

  String? _token;
  Bootstrap? _bootstrap;
  bool _loading = false;
  Object? _error;
  int _authGeneration = 0;
  bool _authBusy = false;
  bool _disposed = false;

  /// 消息中心刷新信号。点「消息」Tab、App 恢复前台、前台收到推送时自增；
  /// 消息页监听它并重新拉取列表（消息页常驻 Tab 不会自己重建，故需外部触发）。
  final ValueNotifier<int> messagesRefreshSignal = ValueNotifier<int>(0);

  /// 聊天刷新信号。前台收到聊天 push / App 恢复前台时自增；聊天页监听后静默同步。
  final ValueNotifier<int> chatRefreshSignal = ValueNotifier<int>(0);

  /// 请求消息页刷新（并顺带刷新 bootstrap，更新未读角标）。
  void requestMessagesRefresh() {
    messagesRefreshSignal.value++;
    unawaited(refresh());
  }

  void requestChatRefresh() {
    chatRefreshSignal.value++;
  }

  AuthSnapshot get authSnapshot => (generation: _authGeneration, token: _token);
  bool isCurrentAuth(AuthSnapshot snapshot) =>
      !_disposed && snapshot == authSnapshot;

  Future<void> clearAuthIfCurrent(AuthSnapshot snapshot) async {
    if (isCurrentAuth(snapshot)) await clearAuth();
  }

  bool get isLoggedIn => _token != null && _token!.isNotEmpty;
  Bootstrap? get bootstrap => _bootstrap;
  bool get loading => _loading;
  Object? get error => _error;

  WoUser? get user => _bootstrap?.user;
  Family? get currentFamily => _bootstrap?.currentFamily;
  String? get currentFamilyId => _bootstrap?.currentFamily?.id;
  List<Family> get families => _bootstrap?.families ?? const [];
  int get unreadCount => _bootstrap?.unreadCount ?? 0;

  /// 启动时恢复登录态。本地有 token 用本地的；否则若构建期通过 WO_USER_ID 强制了
  /// 身份就用它（调试用），都没有则为未登录。
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kToken);
    if (stored != null && stored.isNotEmpty) {
      // 真实会话令牌走 Bearer。
      _token = stored;
      api.authToken = stored;
    } else if (ApiConfig.devUserId.isNotEmpty) {
      // 仅 dev：用 X-User-Id 调试通道免登录（生产后端已关闭）。
      _token = ApiConfig.devUserId;
      api.userId = ApiConfig.devUserId;
    } else {
      _token = null;
    }
    notifyListeners();
    // 已登录则在后台补登设备 token（不阻塞启动流程）。
    if (isLoggedIn) unawaited(_syncPushRegistration());
  }

  /// 启动时读出本地保存的外观偏好。无记录则使用默认「日落影院 · 深色」。
  /// 在 runApp 前调用，避免首帧用错主题再闪一下。
  Future<void> loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    themeMode.value = _decodeThemeMode(prefs.getString(_kThemeMode));
  }

  /// 切换外观并持久化。
  Future<void> setThemeMode(ThemeMode mode) async {
    if (themeMode.value == mode) return;
    themeMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, _encodeThemeMode(mode));
  }

  static ThemeMode _decodeThemeMode(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.dark;
    }
  }

  static String _encodeThemeMode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  /// 手机号 + 密码登录/注册：成功后持久化身份并拉取首屏数据。
  Future<AuthResult> login(String phone, String password) async {
    if (_authBusy) throw StateError('认证请求正在处理中');
    _authBusy = true;
    final generation = ++_authGeneration;
    try {
      final result = await api.login(phone, password);
      if (_disposed || generation != _authGeneration) {
        unawaited(api.discardLoginToken(result.token).catchError((_) {}));
        throw StateError('登录已中断，请重试');
      }
      _token = result.token;
      api.authToken = result.token;
      api.userId = '';
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || generation != _authGeneration) {
        unawaited(api.discardLoginToken(result.token).catchError((_) {}));
        throw StateError('登录已中断，请重试');
      }
      await prefs.setString(_kToken, result.token);
      if (_disposed || generation != _authGeneration) {
        await prefs.remove(_kToken);
        unawaited(api.discardLoginToken(result.token).catchError((_) {}));
        throw StateError('登录已中断，请重试');
      }
      await load();
      if (!isLoggedIn || generation != _authGeneration) {
        throw StateError('登录已失效，请重试');
      }
      unawaited(_syncPushRegistration());
      return result;
    } finally {
      _authBusy = false;
    }
  }

  /// 当前登出离线时仍清本地；全部撤销失败则保留状态，让用户重试。
  Future<void> logout({bool all = false}) async {
    _authGeneration++;
    final snapshot = authSnapshot;
    if (all) {
      await api.logoutAll();
    } else {
      try {
        await api.logout();
      } catch (_) {/* 离线本地退出。 */}
    }
    await clearAuthIfCurrent(snapshot);
  }

  Future<void> changePassword(String oldPassword, String newPassword) async {
    final snapshot = authSnapshot;
    await api.changePassword(
      oldPassword: oldPassword,
      newPassword: newPassword,
    );
    await clearAuthIfCurrent(snapshot);
  }

  /// 会话撤销、过期和改密共用同一清理路径；先清内存，阻止继续发送旧令牌。
  Future<void> clearAuth() async {
    final generation = ++_authGeneration;
    _token = null;
    api.authToken = '';
    api.userId = '';
    _bootstrap = null;
    _loading = false;
    _error = null;
    if (!_disposed) notifyListeners();
    await _clearLocalAuth(generation);
    if (generation == _authGeneration) await MemoryCache.clearAll();
  }

  /// 清掉本地登录态（持久化 token + 内存令牌/身份）。不发网络请求。
  Future<void> _clearLocalAuth(int generation) async {
    final prefs = await SharedPreferences.getInstance();
    if (generation == _authGeneration) await prefs.remove(_kToken);
  }

  /// 取本机 registration id 并上报后端。任何失败都吞掉——推送注册是尽力而为，
  /// 不能拖累登录/启动主流程；下次登录或启动会再试。
  Future<void> _syncPushRegistration() async {
    final p = push;
    if (p == null || !isLoggedIn) return;
    try {
      final rid = await p.currentRegistrationId();
      if (rid != null && rid.isNotEmpty) {
        await api.registerDevice(registrationId: rid, platform: p.platform);
      }
    } catch (_) {
      // 忽略：尽力而为。
    }
  }

  /// 拉取首屏聚合数据。
  Future<void> load() async {
    final generation = _authGeneration;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final data = await api.bootstrap();
      if (_disposed || generation != _authGeneration) return;
      _bootstrap = data;
    } catch (e) {
      if (_disposed || generation != _authGeneration) return;
      // 令牌失效/过期（含旧版本遗留的非会话令牌）→ 清登录态，让路由回登录页。
      if (e is ApiException &&
          (e.statusCode == 401 || e.code == 'UNAUTHORIZED')) {
        await clearAuth();
        return;
      }
      _error = e;
    } finally {
      if (!_disposed && generation == _authGeneration) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// 重新拉取 bootstrap（创建/加入家庭、切换、装/卸插件后调用）。
  Future<void> refresh() => load();

  /// 将已保存的家庭资料同步到首页，不依赖额外请求，也不清空插件列表。
  void updateFamilySnapshot(Family family) {
    final data = _bootstrap;
    if (data == null) return;
    _bootstrap = Bootstrap(
      user: data.user,
      currentFamily:
          data.currentFamily?.id == family.id ? family : data.currentFamily,
      families: [
        for (final item in data.families) item.id == family.id ? family : item,
      ],
      installedPlugins: data.installedPlugins,
      unreadCount: data.unreadCount,
    );
    notifyListeners();
  }

  /// 切换当前家庭，然后刷新缓存。
  Future<void> switchFamily(String familyId) async {
    await api.switchFamily(familyId);
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _authGeneration++;
    api.onSessionInvalid = null;
    messagesRefreshSignal.dispose();
    chatRefreshSignal.dispose();
    themeMode.dispose();
    appUpdate.dispose();
    super.dispose();
  }
}

/// 把 [WoSession] 注入 widget 树。页面用 `WoScope.of(context)` / `WoScope.api(context)`。
class WoScope extends InheritedNotifier<WoSession> {
  const WoScope({
    super.key,
    required WoSession session,
    required super.child,
  }) : super(notifier: session);

  static WoSession of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<WoScope>();
    assert(scope?.notifier != null, 'WoScope 未在 widget 树上层提供');
    return scope!.notifier!;
  }

  /// 只取 api、不订阅状态变化（写操作场景）。
  static WoApi api(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<WoScope>();
    assert(scope?.notifier != null, 'WoScope 未在 widget 树上层提供');
    return scope!.notifier!.api;
  }
}
