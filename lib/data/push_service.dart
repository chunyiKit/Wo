/// 通知适配接口。重建版本不加载旧云推送 SDK、不注册旧后端设备。
/// 本机系统提醒与前台局域网消息将在各自模块实现，不把空回调当成功推送。
abstract interface class PushService {
  String get platform;
  void Function(Map<String,dynamic> event)? get onOpenNotification;
  set onOpenNotification(void Function(Map<String,dynamic> event)? value);
  void Function()? get onInboxShouldRefresh;
  set onInboxShouldRefresh(void Function()? value);
  Future<void> init();
  Future<String?> currentRegistrationId({int retries=6,Duration gap=const Duration(seconds:2)});
}
