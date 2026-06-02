import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// 定位结果:成功带经纬度,失败带原因文案。
class LocationResult {
  const LocationResult.ok(this.latitude, this.longitude) : error = null;
  const LocationResult.failed(this.error)
      : latitude = null,
        longitude = null;

  final double? latitude;
  final double? longitude;
  final String? error;

  bool get ok => error == null;
}

// 取一次定位的最长等待:超时就别再干等(室内 / MIUI 上 GPS 可能迟迟拿不到 fix)。
const _kFixTimeout = Duration(seconds: 12);

void _log(String msg) => debugPrint('[plant-loc] $msg');

/// 申请定位权限并读取当前坐标(安卓优先,iOS 兼容)。
///
/// 全程不抛异常,失败原因以中文文案放进 [LocationResult.error],由调用方提示。
/// 关键:`getCurrentPosition` 一定带 `timeLimit`,超时后退回「上次已知位置」,
/// 否则在拿不到 GPS fix 的环境会永远卡在「定位中」。每步打 `[plant-loc]` 日志,
/// 方便用 logcat(过滤 tag `flutter`)排查卡点。
Future<LocationResult> getCurrentLocation() async {
  try {
    _log('开始:检查定位服务是否开启');
    if (!await Geolocator.isLocationServiceEnabled()) {
      _log('定位服务未开启');
      return const LocationResult.failed('设备定位服务未开启,请到系统设置中打开');
    }

    _log('检查权限');
    var permission = await Geolocator.checkPermission();
    _log('当前权限=$permission');
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      _log('申请后权限=$permission');
    }
    if (permission == LocationPermission.denied) {
      return const LocationResult.failed('未授予定位权限');
    }
    if (permission == LocationPermission.deniedForever) {
      return const LocationResult.failed('定位权限被永久拒绝,请到系统设置中开启');
    }

    // 先用「上次已知位置」:基本瞬时,对“查当地天气”这种粗定位足够。MIUI/室内
    // getCurrentPosition 常常迟迟拿不到新 fix,先用缓存能避免干等十几秒。
    _log('先取上次已知位置');
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) {
      _log('用上次已知位置 ${last.latitude},${last.longitude}');
      return LocationResult.ok(last.latitude, last.longitude);
    }

    // 没有缓存位置(罕见,如刚开机/首次开启定位):再等一次新 fix。
    _log('无缓存,请求新坐标(最长等 ${_kFixTimeout.inSeconds}s)…');
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: _kFixTimeout,
        ),
      );
      _log('拿到新坐标 ${pos.latitude},${pos.longitude}');
      return LocationResult.ok(pos.latitude, pos.longitude);
    } on TimeoutException {
      _log('getCurrentPosition 超时且无缓存');
      return const LocationResult.failed('定位超时,换到窗边或室外再试一次');
    }
  } catch (e) {
    _log('定位异常:$e');
    // 兜底:任何异常也试一下上次已知位置,实在没有再报错。
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        _log('异常后用上次已知位置 ${last.latitude},${last.longitude}');
        return LocationResult.ok(last.latitude, last.longitude);
      }
    } catch (_) {}
    return LocationResult.failed('定位失败:$e');
  }
}
