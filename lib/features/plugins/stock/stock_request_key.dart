import 'dart:convert';
import 'package:uuid/uuid.dart';

/// 相同表单内容失败重试沿用标识，修改内容产生新标识。
class StockRequestKey {
  String? _body;
  String? _id;
  String forBody(Object body) {
    final encoded = jsonEncode(body);
    if (_body != encoded || _id == null) {
      _body = encoded;
      _id = const Uuid().v4();
    }
    return _id!;
  }
}
