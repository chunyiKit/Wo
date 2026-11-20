import 'package:flutter/material.dart';
import '../../../local/local_runtime.dart';

/// 两个原有 tab 共享本机变化监听；页面自己保留列表并静默刷新。
mixin StockLocalRefresh<T extends StatefulWidget> on State<T> {
  LocalRuntime? _stockRuntime;
  void bindStockChanges(bool local) {
    final next = local ? LocalRuntime.instance : null;
    if (identical(next, _stockRuntime)) return;
    _stockRuntime?.changes.removeListener(_stockChanged);
    _stockRuntime = next;
    _stockRuntime?.changes.addListener(_stockChanged);
  }
  void _stockChanged() { if (mounted) onStockLocalChanged(); }
  void onStockLocalChanged();
  @override
  void dispose() {
    _stockRuntime?.changes.removeListener(_stockChanged);
    super.dispose();
  }
}
