import 'dart:io';
import 'package:flutter/services.dart';

/// 在首次打开数据库/身份/配置文件前调用；平台失败时不继续写持久数据。
class LocalPrivacy {
  LocalPrivacy._();
  static const channel = MethodChannel('wo.local/privacy');

  static Future<void> prepare() async {
    if (!Platform.isIOS) return;
    final result = await channel.invokeMapMethod<String, dynamic>('prepare');
    if (result?['documents'] != true || result?['library'] != true) {
      throw StateError('无法确认本机资料已排除系统备份，未初始化本地数据');
    }
  }
}
