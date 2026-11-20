/// 仅本设备消息中心支持的站内来源；push_enabled为既有API兼容字段，不代表OS推送。
class LocalNotificationPreferences {
  const LocalNotificationPreferences({required this.enabled,required this.expirySourceEnabled});
  static const privateKey='notification-preferences';
  static const defaults=LocalNotificationPreferences(enabled:true,expirySourceEnabled:true);
  static const disabled=LocalNotificationPreferences(enabled:false,expirySourceEnabled:false);
  final bool enabled,expirySourceEnabled;
  bool get expiryEnabled=>enabled&&expirySourceEnabled;
  factory LocalNotificationPreferences.fromPrivateValue(Object? value){
    if(value==null)return defaults;
    if(value is! Map||value.containsKey('push_enabled')&&value['push_enabled'] is! bool)return disabled;
    final enabled=value['push_enabled'] as bool? ?? true,sources=value['sources'];
    if(sources==null)return value.containsKey('sources')?disabled:LocalNotificationPreferences(enabled:enabled,expirySourceEnabled:true);
    if(sources is Map){
      if(sources.containsKey('expiry')&&sources['expiry'] is! bool)return disabled;
      return LocalNotificationPreferences(enabled:enabled,expirySourceEnabled:sources['expiry'] as bool? ?? true);
    }
    // 只兼容旧列表形状；保留总开关，不把旧labels或其它来源当当前能力。
    if(sources is List){
      var expiry=true;
      for(final row in sources){
        if(row is! Map)return disabled;
        if(row['key']=='expiry'){
          if(row['enabled'] is! bool)return disabled;
          expiry=row['enabled'] as bool;
        }
      }
      return LocalNotificationPreferences(enabled:enabled,expirySourceEnabled:expiry);
    }
    return disabled;
  }
  Map<String,dynamic> toPrivateValue()=>{'push_enabled':enabled,'sources':{'expiry':expirySourceEnabled}};
  Map<String,dynamic> toApiJson()=>{'push_enabled':enabled,'sources':[
    {'key':'expiry','label':'到期物品','emoji':'📄','enabled':expirySourceEnabled}],
    'delivery':'local_message_center','system_push_supported':false};
}
