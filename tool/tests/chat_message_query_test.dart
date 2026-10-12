// 无第三方依赖的查询构造回归：dart tool/tests/chat_message_query_test.dart
import 'dart:convert';
import 'dart:io';
import '../../lib/data/chat_message_query.dart';

void main(List<String> args) {
  if (args.isNotEmpty) {
    final input = jsonDecode(args.single) as Map<String, dynamic>;
    final query = ChatMessageQuery(
      ownerUserId: input['owner'],
      familyId: input['family'],
      from: ChatMessageCursor(input['time'], input['id']),
      retainedLocalIds: (input['retained'] as List).cast<int>(),
      limit: null,
    );
    stdout.writeln(jsonEncode({'where': query.where, 'args': query.whereArgs}));
    return;
  }
  final cursor = ChatMessageCursor('2026-06-25T10:00:00.000Z', 501);
  final latest = ChatMessageQuery(ownerUserId: 'u1', familyId: 'f1');
  final older = ChatMessageQuery(
      ownerUserId: 'u1', familyId: 'f1', before: cursor, limit: 501);
  final window = ChatMessageQuery(
      ownerUserId: 'u1', familyId: 'f1', from: cursor, limit: null);
  void check(bool condition) {
    if (!condition) throw StateError('查询构造回归失败');
  }

  check(latest.limit == 500);
  check(older.whereArgs.join('|') ==
      'u1|f1|${cursor.createdAt}|${cursor.createdAt}|501');
  check(window.limit == null);
  for (final badLimit in [0, -1]) {
    var rejected = false;
    try {
      ChatMessageQuery(ownerUserId: 'u1', familyId: 'f1', limit: badLimit);
    } on ArgumentError {
      rejected = true;
    }
    check(rejected);
  }
  var rejected = false;
  try {
    ChatMessageQuery(
        ownerUserId: 'u1', familyId: 'f1', before: cursor, from: cursor);
  } on ArgumentError {
    rejected = true;
  }
  check(rejected);
  // 将真实构造器输出交给 SQLite 测试，不在测试里复制生产 SQL。
  stdout.writeln(jsonEncode({
    'latest': latest.where,
    'older': older.where,
    'window': window.where,
    'order': ChatMessageQuery.orderBy,
  }));
}
