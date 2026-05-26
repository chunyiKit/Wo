import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:jpush_flutter/jpush_flutter.dart';
import 'package:jpush_flutter/jpush_interface.dart';
import 'package:permission_handler/permission_handler.dart';

/// 极光推送（远程推送主干道）的客户端封装。
///
/// 职责边界：本类只负责"初始化 SDK + 申请通知权限 + 拿到本机 registration id +
/// 处理推送事件"。**把 registration id 上报给后端 `/devices/register` 是
/// [WoSession] 的事**——因为上报需要当前登录身份（X-User-Id），由会话层统一在
/// 登录/启动时调用 [currentRegistrationId] 再上报。
///
/// 仅在 Android / iOS 真机环境生效；其他平台（含单元测试）所有方法安全降级为
/// no-op，不触碰平台通道。
class PushService {
  PushService({
    required this.appKey,
    required this.channel,
  });

  final String appKey;
  final String channel;

  final JPushFlutterInterface _jpush = JPush.newJPush();
  bool _initialized = false;
  bool get _supported => Platform.isAndroid || Platform.isIOS;

  /// 当前平台标识，用于 `/devices/register` 的 platform 字段。
  String get platform => Platform.isIOS ? 'ios' : 'android';

  /// 可选：通知被点击时的回调（用于 deeplink 跳转）。由上层注入。
  void Function(Map<String, dynamic> event)? onOpenNotification;

  /// 可选：消息中心可能有新内容时的回调（前台收到 / 点开推送时触发）。
  /// 上层据此刷新消息列表与未读角标。
  void Function()? onInboxShouldRefresh;

  /// 初始化极光 SDK 并申请通知权限。重复调用安全（只跑一次）。
  Future<void> init() async {
    if (_initialized || !_supported) return;
    _initialized = true;

    _jpush.addEventHandler(
      // 前台收到通知 / 点开通知 都意味着消息中心有新内容，触发上层刷新。
      onReceiveNotification: _handleInbox('onReceiveNotification'),
      onOpenNotification: _handleOpen,
      onReceiveMessage: _handleInbox('onReceiveMessage'),
    );

    // 必须先 setup 才能用其他能力。production 控制 iOS APNs 网关（沙箱/正式），
    // 与后端 JPUSH_APNS_PRODUCTION 对齐；Android 不受此影响。
    _jpush.setup(
      appKey: appKey,
      channel: channel,
      production: false,
      debug: !kReleaseMode,
    );
    // iOS 推送授权弹窗（Android 为 no-op）。
    _jpush.applyPushAuthority(
      const NotificationSettingsIOS(sound: true, alert: true, badge: true),
    );

    await _ensureNotificationPermission();
  }

  /// 申请 Android 13+ 的 POST_NOTIFICATIONS 运行时权限。低版本系统、iOS 由系统/
  /// applyPushAuthority 处理，permission_handler 在这些情况下直接返回已授权。
  Future<void> _ensureNotificationPermission() async {
    try {
      final status = await Permission.notification.status;
      if (!status.isGranted) {
        await Permission.notification.request();
      }
    } catch (_) {
      // 个别 ROM / 平台不支持查询时忽略，不阻断初始化。
    }
  }

  /// 取本机 registration id；首次注册可能要几秒才生成，故带有限次重试。
  /// 拿不到返回 null（上层下次登录/启动会再试）。
  Future<String?> currentRegistrationId({
    int retries = 6,
    Duration gap = const Duration(seconds: 2),
  }) async {
    if (!_supported) return null;
    for (var attempt = 0; attempt < retries; attempt++) {
      try {
        final rid = await _jpush.getRegistrationID();
        if (rid.isNotEmpty) return rid;
      } catch (_) {
        // 通道未就绪等，吞掉后重试。
      }
      if (attempt < retries - 1) await Future<void>.delayed(gap);
    }
    return null;
  }

  Future<dynamic> _handleOpen(Map<String, dynamic> event) async {
    if (kDebugMode) debugPrint('[push] onOpenNotification: $event');
    onInboxShouldRefresh?.call();
    onOpenNotification?.call(event);
  }

  // 返回类型显式写出，避免 jpush 两个库都导出的 `EventHandler` typedef 造成歧义。
  Future<dynamic> Function(Map<String, dynamic>) _handleInbox(String name) =>
      (Map<String, dynamic> event) async {
        if (kDebugMode) debugPrint('[push] $name: $event');
        onInboxShouldRefresh?.call();
      };
}
