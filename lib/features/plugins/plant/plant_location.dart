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

/// 申请定位权限并读取当前坐标(安卓优先,iOS 兼容)。
///
/// 全程不抛异常,失败原因以中文文案放进 [LocationResult.error],由调用方提示。
Future<LocationResult> getCurrentLocation() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return const LocationResult.failed('设备定位服务未开启,请到系统设置中打开');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      return const LocationResult.failed('未授予定位权限');
    }
    if (permission == LocationPermission.deniedForever) {
      return const LocationResult.failed('定位权限被永久拒绝,请到系统设置中开启');
    }
    final pos = await Geolocator.getCurrentPosition(
      locationSettings:
          const LocationSettings(accuracy: LocationAccuracy.medium),
    );
    return LocationResult.ok(pos.latitude, pos.longitude);
  } catch (e) {
    return LocationResult.failed('定位失败:$e');
  }
}
