import 'package:flutter/material.dart';

/// 倒序布局让“加载更早”只在滚动末端增加行；内容变高时补偿可见锚点。
class ChatHistoryList<T> extends StatefulWidget {
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
  State<ChatHistoryList<T>> createState() => _ChatHistoryListState<T>();
}

class _ChatHistoryListState<T> extends State<ChatHistoryList<T>> {
  final _rowKeys = <Key, GlobalKey>{};
  final _viewportKey = GlobalKey();
  int _revision = 0;

  @override
  void didUpdateWidget(covariant ChatHistoryList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final revision = ++_revision;
    final controller = widget.controller;
    if (controller != oldWidget.controller ||
        !controller.hasClients ||
        controller.offset < 80) return;
    final viewport =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.hasSize) return;
    final top = viewport.localToGlobal(Offset.zero).dy;
    final bottom = top + viewport.size.height;
    GlobalKey? anchor;
    double? anchorY;
    for (final key in _rowKeys.values) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero).dy;
      if (y < bottom &&
          y + box.size.height > top &&
          (anchorY == null || y < anchorY)) {
        anchor = key;
        anchorY = y;
      }
    }
    if (anchor == null) return;
    final savedOffset = controller.offset;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          revision != _revision ||
          !controller.hasClients ||
          controller.position.isScrollingNotifier.value ||
          controller.offset != savedOffset) return;
      final box = anchor!.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final delta = anchorY! - box.localToGlobal(Offset.zero).dy;
      if (delta.abs() < 0.5) return;
      controller.jumpTo(
        (savedOffset + delta).clamp(
          controller.position.minScrollExtent,
          controller.position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final indices = <Key, int>{
      for (var i = 0; i < widget.items.length; i++)
        widget.itemKey(widget.items[i]): widget.items.length - i - 1,
    };
    _rowKeys.removeWhere((key, _) => !indices.containsKey(key));
    return ListView.builder(
      key: _viewportKey,
      controller: widget.controller,
      reverse: true,
      padding: widget.padding,
      itemCount: widget.items.length + (widget.hasOlder ? 1 : 0),
      findChildIndexCallback: (key) => indices[key],
      itemBuilder: (_, index) {
        if (index == widget.items.length) {
          return Center(
            child: TextButton(
              onPressed: widget.loadingOlder ? null : widget.onLoadOlder,
              child: Text(widget.loadingOlder ? '加载中…' : '加载更早的消息'),
            ),
          );
        }
        final item = widget.items[widget.items.length - index - 1];
        final key = widget.itemKey(item);
        return KeyedSubtree(
          key: key,
          child: KeyedSubtree(
            key: _rowKeys.putIfAbsent(key, GlobalKey.new),
            child: widget.itemBuilder(item),
          ),
        );
      },
    );
  }
}
