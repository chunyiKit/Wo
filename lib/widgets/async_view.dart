import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../theme/wo_tokens.dart';

/// 统一的异步数据视图：处理加载中 / 出错（带重试）/ 数据三种状态。
///
/// 用法：
/// ```dart
/// AsyncView<List<Plugin>>(
///   future: _future,
///   onRetry: () => setState(() => _future = api.plugins()),
///   builder: (ctx, data) => ...,
/// )
/// ```
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.future,
    required this.builder,
    this.onRetry,
    this.loadingBuilder,
  });

  final Future<T> future;
  final Widget Function(BuildContext context, T data) builder;
  final VoidCallback? onRetry;

  /// 首屏加载占位。默认转圈；传入可换成骨架屏等更高级的占位。
  final WidgetBuilder? loadingBuilder;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return loadingBuilder?.call(context) ??
              const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _ErrorState(error: snap.error!, onRetry: onRetry);
        }
        if (!snap.hasData) {
          return _ErrorState(error: '没有数据', onRetry: onRetry);
        }
        return builder(context, snap.data as T);
      },
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final message = switch (error) {
      ApiException e => e.message,
      NetworkException e => e.message,
      _ => error.toString(),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WoTokens.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('😣', style: TextStyle(fontSize: 40)),
            const SizedBox(height: WoTokens.space4),
            Text(
              '加载失败',
              style: t.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space2),
            Text(
              message,
              style: t.bodySmall?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: WoTokens.space5),
              FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}
