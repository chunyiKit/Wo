import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../local/local_runtime.dart';
import '../../../theme/wo_tokens.dart';

class FinanceRequestKey {
  String? _body, _id;
  String forBody(Object body) {
    final encoded = jsonEncode(body);
    if (encoded != _body || _id == null) { _body = encoded; _id = const Uuid().v4(); }
    return _id!;
  }
}

/// Canonical decimal text; local writes never round via a binary double.
String financeAmount(String text, {bool negative = false, bool emptyZero = false, bool subscription = false}) {
  if (emptyZero && text.trim().isEmpty) return '0.00';
  final value = text.trim();
  if (!RegExp(r'^-?[0-9]{1,12}(\.[0-9]{1,2})?$').hasMatch(value)) throw const FormatException('金额最多两位小数，请填写准确金额');
  final minus = value.startsWith('-');
  final parts = (minus ? value.substring(1) : value).split('.');
  final minor = int.parse(parts[0]) * 100 + (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
  if (minor > (subscription ? 999999999999 : 99999999999999) || minus && !negative && minor != 0 || subscription && minor == 0) throw const FormatException('金额超出范围');
  return '${minus && minor != 0 ? '-' : ''}${minor ~/ 100}.${(minor % 100).toString().padLeft(2, '0')}';
}

mixin FinanceLocalRefresh<T extends StatefulWidget> on State<T> {
  LocalRuntime? _financeRuntime;
  void bindFinanceChanges(bool local) {
    final next = local ? LocalRuntime.instance : null;
    if (identical(next, _financeRuntime)) return;
    _financeRuntime?.changes.removeListener(_changed);
    _financeRuntime = next;
    _financeRuntime?.changes.addListener(_changed);
  }
  void _changed() { if (mounted) onFinanceChanged(); }
  void onFinanceChanged();
  @override
  void dispose() { _financeRuntime?.changes.removeListener(_changed); super.dispose(); }
}

class LocalFinanceStatus extends StatelessWidget {
  const LocalFinanceStatus({super.key});
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(WoTokens.space3), child: Text(
    '本地模式：打开 App 时处理账期。后台执行与历史补算尚未完成；提醒待本机投递，不代表已送达。',
    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: context.wo.fgMid)));
}
