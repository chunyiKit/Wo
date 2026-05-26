import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'api_config.dart';
import 'models.dart';
import 'push_service.dart';
import 'wo_api.dart';

/// 全局会话状态：持有 [WoApi]、管理登录身份（手机号登录拿到的 user id，持久化到
/// 本地），并缓存一次性的 bootstrap 结果。
///
/// 身份目前就是 user id（后端 dev shim 用 X-User-Id 头识别）；接真实 JWT 后只需
/// 把存的 token 换成 JWT、ApiClient 改发 Authorization 头即可，上层流程不变。
class WoSession extends ChangeNotifier {
  WoSession({WoApi? api, this.push}) : api = api ?? WoApi(ApiClient());

  static const _kToken = 'wo.token';
  static const _kThemeMode = 'wo.themeMode';

  final WoApi api;

  /// 外观主题：浅色 / 深色 / 跟随系统（默认）。本地持久化，启动时由
  /// [loadThemeMode] 读出。用 ValueNotifier 单独承载，避免主题切换牵动其他 UI。
  final ValueNotifier<ThemeMode> themeMode =
      ValueNotifier<ThemeMode>(ThemeMode.system);

  /// 可选的推送服务。注入后会在登录/启动时上报本机 registration id、登出时注销。
  /// 测试与非移动端不注入（为 null），相关逻辑自动跳过。
  final PushService? push;

  String? _token;
  Bootstrap? _bootstrap;
  bool _loading = false;
  Object? _error;

  /// 消息中心刷新信号。点「消息」Tab、App 恢复前台、前台收到推送时自增；
  /// 消息页监听它并重新拉取列表（消息页常驻 Tab 不会自己重建，故需外部触发）。
  final ValueNotifier<int> messagesRefreshSignal = ValueNotifier<int>(0);

  /// 请求消息页刷新（并顺带刷新 bootstrap，更新未读角标）。
  void requestMessagesRefresh() {
    messagesRefreshSignal.value++;
    unawaited(refresh());
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
    final token = (stored != null && stored.isNotEmpty)
        ? stored
        : (ApiConfig.devUserId.isNotEmpty ? ApiConfig.devUserId : null);
    _token = token;
    api.userId = token ?? '';
    notifyListeners();
    // 已登录则在后台补登设备 token（不阻塞启动流程）。
    if (isLoggedIn) unawaited(_syncPushRegistration());
  }

  /// 启动时读出本地保存的外观偏好。无记录则保持默认「跟随系统」。
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
      default:
        return ThemeMode.system;
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

  /// 手机号登录/注册：成功后持久化身份并拉取首屏数据。
  Future<AuthResult> login(String phone) async {
    final result = await api.login(phone);
    _token = result.token;
    api.userId = result.token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, result.token);
    await load();
    // 上报本机推送 token（后台进行，失败不影响登录）。
    unawaited(_syncPushRegistration());
    return result;
  }

  /// 退出登录：清掉身份与缓存。
  Future<void> logout() async {
    // 先注销设备 token（此时 X-User-Id 仍在，后端才能定位并删除）。
    await _clearPushRegistration();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    _token = null;
    api.userId = '';
    _bootstrap = null;
    _error = null;
    notifyListeners();
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

  /// 登出时注销本机 token。拿不到 id 或网络失败都安全忽略。
  Future<void> _clearPushRegistration() async {
    final p = push;
    if (p == null) return;
    try {
      final rid = await p.currentRegistrationId(retries: 1);
      if (rid != null && rid.isNotEmpty) {
        await api.unregisterDevice(rid);
      }
    } catch (_) {
      // 忽略。
    }
  }

  /// 拉取首屏聚合数据。
  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _bootstrap = await api.bootstrap();
    } catch (e) {
      _error = e;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 重新拉取 bootstrap（创建/加入家庭、切换、装/卸插件后调用）。
  Future<void> refresh() => load();

  /// 切换当前家庭，然后刷新缓存。
  Future<void> switchFamily(String familyId) async {
    await api.switchFamily(familyId);
    await refresh();
  }

  @override
  void dispose() {
    messagesRefreshSignal.dispose();
    themeMode.dispose();
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
