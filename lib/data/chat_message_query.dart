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
      where += windowPredicate;
      whereArgs.addAll([from.createdAt, from.createdAt, from.localId]);
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
