import 'package:flutter/material.dart';

/// 倒序布局让“加载更早”只在滚动末端增加行，已有消息的位置保持不变。
class ChatHistoryList<T> extends StatelessWidget {
  const ChatHistoryList({
    super.key,
    required this.items,
    required this.controller,
    required this.hasOlder,
    required this.loadingOlder,
    required this.onLoadOlder,
    required this.itemBuilder,
    required this.itemKey,
    this.padding,
  });

  final List<T> items;
  final ScrollController controller;
  final bool hasOlder;
  final bool loadingOlder;
  final VoidCallback onLoadOlder;
  final Widget Function(T) itemBuilder;
  final Key Function(T) itemKey;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => ListView.builder(
        controller: controller,
        reverse: true,
        padding: padding,
        itemCount: items.length + (hasOlder ? 1 : 0),
        itemBuilder: (_, index) {
          if (index == items.length) {
            return Center(
              child: TextButton(
                onPressed: loadingOlder ? null : onLoadOlder,
                child: Text(loadingOlder ? '加载中…' : '加载更早的消息'),
              ),
            );
          }
          final item = items[items.length - index - 1];
          return KeyedSubtree(key: itemKey(item), child: itemBuilder(item));
        },
      );
}
