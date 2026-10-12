/// 本地聊天按 (created_at, local_id) 分页，避免同一时间的消息跨页遗漏。
class ChatMessageCursor {
  const ChatMessageCursor(this.createdAt, this.localId);

  final String createdAt;
  final int localId;
}

class ChatMessageQuery {
  ChatMessageQuery({
    required String ownerUserId,
    required String familyId,
    ChatMessageCursor? before,
    ChatMessageCursor? from,
    this.limit = 500,
    List<int> retainedLocalIds = const [],
  }) {
    if (limit != null && limit! <= 0) {
      throw ArgumentError.value(limit, 'limit', '必须大于 0');
    }
    if (before != null && from != null) {
      throw ArgumentError('before 和 from 不能同时使用');
    }
    whereArgs = [ownerUserId, familyId];
    if (before != null) {
      where += olderPredicate;
      whereArgs.addAll([before.createdAt, before.createdAt, before.localId]);
    }
    if (from != null) {
      where += ' AND (${windowPredicate.substring(5)}';
      whereArgs.addAll([from.createdAt, from.createdAt, from.localId]);
      if (retainedLocalIds.isNotEmpty) {
        // localId 不随服务端确认改变。重新读取已加载消息的最早位置，
        // 避免 created_at 回拨后掉出窗口，并纳入其间的消息。
        // ID 是内部 int；直接生成整数列表，避免展开历史后超过绑定参数上限。
        where += ' OR (created_at, local_id) >= '
            '(SELECT created_at, local_id FROM chat_messages WHERE '
            '$scopePredicate AND local_id IN (${retainedLocalIds.join(',')}) '
            'ORDER BY created_at ASC, local_id ASC LIMIT 1)';
        whereArgs.addAll([ownerUserId, familyId]);
      }
      where += ')';
    }
  }

  static const scopePredicate = 'owner_user_id = ? AND family_id = ?';
  static const olderPredicate =
      ' AND (created_at < ? OR (created_at = ? AND local_id < ?))';
  static const windowPredicate =
      ' AND (created_at > ? OR (created_at = ? AND local_id >= ?))';
  static const orderBy = 'created_at DESC, local_id DESC';

  String where = scopePredicate;
  late final List<Object?> whereArgs;
  final int? limit;
}
