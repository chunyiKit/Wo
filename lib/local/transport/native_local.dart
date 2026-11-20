import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 密钥由调用者短时持有；不得写入日志、SQLite 或普通配置。
/// 所有 AES-GCM nonce 必须在同一 key 下唯一，由上层协议负责。
abstract interface class LocalCrypto {
  Future<Uint8List> random(int count);
  Future<Uint8List> hash(Uint8List bytes);
  Future<Uint8List> hmac({required Uint8List key, required Uint8List data});
  Future<Uint8List> seal({required Uint8List key, required Uint8List nonce,
    required Uint8List plaintext, required Uint8List aad});
  Future<Uint8List> open({required Uint8List key, required Uint8List nonce,
    required Uint8List ciphertext, required Uint8List aad});
  Future<void> putSecret(String handle, Uint8List bytes);
  Future<Uint8List?> getSecret(String handle);
  Future<void> deleteSecret(String handle);
}

final class NativeCrypto implements LocalCrypto {
  NativeCrypto({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('wo.local/crypto');
  final MethodChannel _channel;
  static const maxBytes = 8 * 1024 * 1024;
  static final _handle = RegExp(r'^[A-Za-z0-9_.-]{1,100}$');

  void _size(Uint8List value, int max, String name, {int min = 0}) {
    if (value.length < min || value.length > max) {
      throw ArgumentError.value(value.length, name, 'invalid byte length');
    }
  }
  void _secretHandle(String handle) {
    final match = _handle.firstMatch(handle);
    if (match == null || match.end != handle.length) {
      throw ArgumentError('invalid secret handle');
    }
  }
  void _gcm(Uint8List key, Uint8List nonce, Uint8List aad) {
    _size(key, 32, 'key', min: 32);
    _size(nonce, 12, 'nonce', min: 12);
    _size(aad, 65536, 'aad');
  }
  Future<Uint8List> _bytes(String method, Map<String, Object> args,
      {int? exact, int? length}) async {
    final result = await _channel.invokeMethod<Uint8List>(method, args);
    if (result == null || (exact != null && result.length != exact) ||
        (length != null && result.length != length)) {
      throw PlatformException(code: 'native_contract',
          message: 'Invalid native crypto result');
    }
    return result;
  }
  /// 只返回本App固定私有目录，名称不是路径；路径不得进入同步或普通配置。
  Future<String> privateDirectory(String name)async{
    final match=RegExp(r'^[a-z0-9_-]{1,40}$').firstMatch(name);
    if(match==null||match.end!=name.length)throw ArgumentError('invalid private directory name');
    final path=await _channel.invokeMethod<String>('privateDirectory',{'name':name});
    if(path==null||!path.startsWith('/'))throw StateError('private directory unavailable');return path;
  }
  @override
  Future<Uint8List> random(int count) {
    if (count < 1 || count > 64) throw ArgumentError('count must be 1..64');
    return _bytes('random', {'count': count}, exact: count);
  }
  @override
  Future<Uint8List> hash(Uint8List bytes) {
    _size(bytes, maxBytes, 'bytes');
    return _bytes('hash', {'bytes': bytes}, exact: 32);
  }
  @override
  Future<Uint8List> hmac({required Uint8List key, required Uint8List data}) {
    _size(key, 4096, 'key', min: 1);
    _size(data, maxBytes, 'data');
    return _bytes('hmac', {'key': key, 'data': data}, exact: 32);
  }
  @override
  Future<Uint8List> seal({required Uint8List key, required Uint8List nonce,
      required Uint8List plaintext, required Uint8List aad}) {
    _gcm(key, nonce, aad); _size(plaintext, maxBytes, 'plaintext');
    return _bytes('seal', {'key': key, 'nonce': nonce,
      'plaintext': plaintext, 'aad': aad}, length: plaintext.length + 16);
  }
  @override
  Future<Uint8List> open({required Uint8List key, required Uint8List nonce,
      required Uint8List ciphertext, required Uint8List aad}) {
    _gcm(key, nonce, aad); _size(ciphertext, maxBytes + 16, 'ciphertext', min: 16);
    return _bytes('open', {'key': key, 'nonce': nonce,
      'ciphertext': ciphertext, 'aad': aad}, length: ciphertext.length - 16);
  }
  @override
  Future<void> putSecret(String handle, Uint8List bytes) async {
    _secretHandle(handle); _size(bytes, 4096, 'bytes');
    await _channel.invokeMethod<void>('putSecret', {'handle': handle, 'bytes': bytes});
  }
  @override
  Future<Uint8List?> getSecret(String handle) async {
    _secretHandle(handle);
    final result = await _channel.invokeMethod<Uint8List>('getSecret', {'handle': handle});
    if (result != null) _size(result, 4096, 'native secret');
    return result;
  }
  @override
  Future<void> deleteSecret(String handle) async {
    _secretHandle(handle);
    await _channel.invokeMethod<void>('deleteSecret', {'handle': handle});
  }
}

/// 发现只是未经认证的地址提示；只有协议握手才决定身份和权限。
final class LocalDiscoveryEvent {
  const LocalDiscoveryEvent({required this.event, required this.deviceId,
    required this.address, required this.port});
  final String event;
  final String deviceId;
  final String address;
  final int port;
  static final opaqueId = RegExp(r'^[A-Za-z0-9_-]{16,48}$');
  static bool isOpaqueId(String value) {
    final match = opaqueId.firstMatch(value);
    return match != null && match.end == value.length;
  }
  factory LocalDiscoveryEvent.fromNative(Object? value) {
    if (value is! Map) throw const FormatException('Invalid discovery event');
    final event = value['event'], id = value['deviceId'];
    final address = value['address'], port = value['port'];
    if ((event != 'found' && event != 'lost') || id is! String ||
        !isOpaqueId(id) || address is! String || address.isEmpty ||
        address.length > 128 || port is! int || port < 1 || port > 65535) {
      throw const FormatException('Invalid discovery event');
    }
    return LocalDiscoveryEvent(event: event as String, deviceId: id,
        address: address, port: port);
  }
}

final class NativeDiscovery {
  NativeDiscovery({MethodChannel? channel, EventChannel? eventChannel})
      : _channel = channel ?? const MethodChannel('wo.local/discovery'),
        _eventChannel = eventChannel ?? const EventChannel('wo.local/discovery/events');
  final MethodChannel _channel;
  final EventChannel _eventChannel;
  Stream<LocalDiscoveryEvent>? _events;
  Stream<LocalDiscoveryEvent> get events => _events ??=
      _eventChannel.receiveBroadcastStream().map(LocalDiscoveryEvent.fromNative);
  Future<void> start({required String serviceName, required int port}) async {
    if (!LocalDiscoveryEvent.isOpaqueId(serviceName) || port < 1 || port > 65535) {
      throw ArgumentError('invalid discovery advertisement');
    }
    await _channel.invokeMethod<void>('start', {'serviceName': serviceName, 'port': port});
  }
  Future<void> stop() async { await _channel.invokeMethod<void>('stop'); }
}
