/// 阅读历史时保持行顺序和数量，只更新稳定 ID 对应的内容。
/// 新增（包括回填）消息留给“查看新消息”入口，避免插入行移动视口。
class ChatHistoryRefresh<T> {
  ChatHistoryRefresh({
    required List<T> previous,
    required List<T> fresh,
    required Object Function(T) id,
    required bool readingHistory,
  }) {
    final previousIds = previous.map(id).toSet();
    hasNewMessages =
        readingHistory && fresh.any((item) => !previousIds.contains(id(item)));
    final byId = {for (final item in fresh) id(item): item};
    items = readingHistory
        ? previous.map((item) => byId[id(item)] ?? item).toList()
        : fresh;
  }

  late final List<T> items;
  late final bool hasNewMessages;
}
