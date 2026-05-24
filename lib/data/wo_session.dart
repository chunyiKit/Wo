import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'api_config.dart';
import 'models.dart';
import 'wo_api.dart';

/// 全局会话状态：持有 [WoApi]、管理登录身份（手机号登录拿到的 user id，持久化到
/// 本地），并缓存一次性的 bootstrap 结果。
///
/// 身份目前就是 user id（后端 dev shim 用 X-User-Id 头识别）；接真实 JWT 后只需
/// 把存的 token 换成 JWT、ApiClient 改发 Authorization 头即可，上层流程不变。
class WoSession extends ChangeNotifier {
  WoSession({WoApi? api}) : api = api ?? WoApi(ApiClient());

  static const _kToken = 'wo.token';

  final WoApi api;

  String? _token;
  Bootstrap? _bootstrap;
  bool _loading = false;
  Object? _error;

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
  }

  /// 手机号登录/注册：成功后持久化身份并拉取首屏数据。
  Future<AuthResult> login(String phone) async {
    final result = await api.login(phone);
    _token = result.token;
    api.userId = result.token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, result.token);
    await load();
    return result;
  }

  /// 退出登录：清掉身份与缓存。
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    _token = null;
    api.userId = '';
    _bootstrap = null;
    _error = null;
    notifyListeners();
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
