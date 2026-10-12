import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wo/data/chat_local_store.dart';
import 'package:wo/data/chat_sync_service.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';

final message = ChatMessage(
  id: 'm1',
  familyId: 'f1',
  clientId: 'c1',
  kind: 'image',
  senderName: '妈妈',
  senderEmoji: '👩',
  createdAt: DateTime.utc(2026),
  image: const ChatImage(
    messageId: 'm1',
    url: '/image',
    contentType: 'image/png',
    sizeBytes: 3,
  ),
);

class MemoryStore implements ChatLocalStore {
  MemoryStore(this.directory);
  final Directory directory;
  final messages = <(String, String, String), ChatLocalMessage>{};
  final attempts = <(String, String, String), int>{};
  final due = <(String, String, String), DateTime>{};
  final states = <(String, String), ChatSyncState>{};

  @override
  Future<List<ChatAttachmentRetry>> pendingAttachments({
    required String ownerUserId,
    required String familyId,
    required DateTime now,
    int limit = 8,
  }) async => messages.entries
      .where(
        (entry) =>
            entry.key.$1 == ownerUserId &&
            entry.key.$2 == familyId &&
            entry.value.imageLocalPath == null &&
            !(due[entry.key] ?? DateTime(2000)).isAfter(now),
      )
      .take(limit)
      .map(
        (entry) => ChatAttachmentRetry(
          message: entry.value,
          attempts: attempts[entry.key] ?? 0,
        ),
      )
      .toList();

  @override
  Future<void> recordAttachmentAttempt({
    required String ownerUserId,
    required String familyId,
    required String serverId,
    required int attempts,
    required DateTime now,
    String? imageLocalPath,
  }) async {
    final key = (ownerUserId, familyId, serverId);
    if (imageLocalPath != null)
      messages[key] = messages[key]!.copyWith(imageLocalPath: imageLocalPath);
    this.attempts[key] = attempts + 1;
    due[key] = now.add(
      Duration(seconds: (30 * (1 << attempts.clamp(0, 6))).clamp(30, 1800)),
    );
  }

  @override
  Future<ChatSyncState> syncState({
    required String ownerUserId,
    required String familyId,
  }) async => states[(ownerUserId, familyId)] ?? const ChatSyncState();

  @override
  Future<void> saveSyncState({
    required String ownerUserId,
    required String familyId,
    required DateTime afterCreatedAt,
    required String afterId,
  }) async {
    states[(ownerUserId, familyId)] = ChatSyncState(
      afterCreatedAt: afterCreatedAt,
      afterId: afterId,
    );
  }

  @override
  Future<ChatLocalMessage?> byServerId({
    required String ownerUserId,
    required String familyId,
    required String serverId,
  }) async => messages[(ownerUserId, familyId, serverId)];

  @override
  Future<void> upsertRemote({
    required String ownerUserId,
    required ChatMessage remote,
    String? imageLocalPath,
  }) async {
    final key = (ownerUserId, remote.familyId, remote.id);
    messages[key] = ChatLocalMessage(
      serverId: remote.id,
      clientId: remote.clientId,
      ownerUserId: ownerUserId,
      familyId: remote.familyId,
      senderName: remote.senderName,
      senderEmoji: remote.senderEmoji,
      kind: remote.kind,
      status: chatStatusSent,
      createdAt: remote.createdAt,
      imageLocalPath: imageLocalPath ?? messages[key]?.imageLocalPath,
      imageRemoteUrl: remote.image?.url,
      imageContentType: remote.image?.contentType,
    );
  }

  @override
  Future<String> imagePath({
    required String ownerUserId,
    required String familyId,
    required String key,
    required String contentType,
  }) async => '${directory.path}/$ownerUserId/$familyId/$key.png';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeApi implements WoApi {
  @override
  String userId = ''; // 正常 Bearer 登录没有开发用 X-User-Id。
  @override
  String authToken = 'token1';
  final cursors = <String?>[];
  @override
  Map<String, String> get imageHeaders => {'Authorization': authToken};
  @override
  String chatImageUrl(ChatImage image) => 'https://example.test${image.url}';
  @override
  Future<({List<ChatMessage> items, String? cursor})> chatMessages(
    String familyId, {
    DateTime? afterCreatedAt,
    String? afterId,
    int limit = 100,
  }) async {
    cursors.add(afterId);
    return (
      items: afterId == null && familyId == 'f1' ? [message] : <ChatMessage>[],
      cursor: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RecordingDatabase implements Database {
  Invocation? last;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    last = invocation;
    if (invocation.memberName == #query)
      return Future.value(<Map<String, Object?>>[]);
    if (invocation.memberName == #update) return Future.value(1);
    return super.noSuchMethod(invocation);
  }
}

void main() {
  late Directory directory;
  late MemoryStore store;
  late FakeApi api;
  late DateTime now;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chat-retry-');
    store = MemoryStore(directory);
    api = FakeApi();
    now = DateTime.utc(2026, 10, 1);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('失败后游标照常推进，重建服务后空增量页也能补图且不会重复下载', () async {
    var requests = 0;
    var healthy = false;
    ChatSyncService service() => ChatSyncService(
      api: api,
      store: store,
      now: () => now,
      imageClientFactory: () => MockClient((request) async {
        requests++;
        return http.Response(healthy ? 'png' : '', healthy ? 200 : 503);
      }),
    );
    await service().sync(ownerUserId: 'u1', familyId: 'f1');
    expect(store.states[('u1', 'f1')]?.afterId, 'm1');
    expect(store.messages[('u1', 'f1', 'm1')]?.imageLocalPath, isNull);
    healthy = true;
    await service().sync(ownerUserId: 'u1', familyId: 'f1');
    expect(requests, 1); // 退避未到，不立即重试。
    now = now.add(const Duration(seconds: 31));
    await service().sync(ownerUserId: 'u1', familyId: 'f1');
    final path = store.messages[('u1', 'f1', 'm1')]!.imageLocalPath!;
    expect(await File(path).readAsString(), 'png');
    await service().sync(ownerUserId: 'u1', familyId: 'f1');
    expect(requests, 2);
    expect(store.messages.length, 1);
    expect(api.cursors, [null, 'm1', 'm1', 'm1']);
  });

  test('同作用域并发同步合并，切换账号后不写旧附件响应', () async {
    final response = Completer<http.Response>();
    final started = Completer<void>();
    var requests = 0;
    final service = ChatSyncService(
      api: api,
      store: store,
      now: () => now,
      imageClientFactory: () => MockClient((_) {
        requests++;
        started.complete();
        return response.future;
      }),
    );
    final first = service.sync(ownerUserId: 'u1', familyId: 'f1');
    final second = service.sync(ownerUserId: 'u1', familyId: 'f1');
    expect(identical(first, second), isTrue);
    await started.future;
    api.userId = 'u2';
    api.authToken = 'token2';
    response.complete(http.Response('png', 200));
    await Future.wait([first, second]);
    expect(requests, 1);
    expect(store.messages.length, 1);
    expect(store.messages[('u1', 'f1', 'm1')]?.imageLocalPath, isNull);
    expect(store.messages.keys.every((key) => key.$1 == 'u1'), isTrue);
    expect(await directory.list(recursive: true).toList(), isEmpty);
  });

  test('另一家庭同步不会读取旧家庭的待重试附件', () async {
    await store.upsertRemote(ownerUserId: 'u1', remote: message);
    var requests = 0;
    final service = ChatSyncService(
      api: api,
      store: store,
      now: () => now,
      imageClientFactory: () => MockClient((_) async {
        requests++;
        return http.Response('png', 200);
      }),
    );
    await service.sync(ownerUserId: 'u1', familyId: 'f2');
    expect(requests, 0);
    expect(store.messages[('u1', 'f1', 'm1')]?.imageLocalPath, isNull);
  });

  test('一轮最多处理八个附件，失败项退避且不饿死后续附件', () async {
    for (var i = 0; i < 9; i++) {
      await store.upsertRemote(
        ownerUserId: 'u1',
        remote: ChatMessage(
          id: 'queued$i',
          familyId: 'f1',
          clientId: 'queued$i',
          kind: 'image',
          senderName: '妈妈',
          senderEmoji: '👩',
          createdAt: now,
          image: ChatImage(
            messageId: 'queued$i',
            url: '/image/$i',
            contentType: 'image/png',
            sizeBytes: 3,
          ),
        ),
      );
    }
    store.states[('u1', 'f1')] = ChatSyncState(
      afterCreatedAt: now,
      afterId: 'last',
    );
    var requests = 0;
    final service = ChatSyncService(
      api: api,
      store: store,
      now: () => now,
      imageClientFactory: () => MockClient((_) async {
        requests++;
        return http.Response('', 503);
      }),
    );
    await service.sync(ownerUserId: 'u1', familyId: 'f1');
    expect(requests, 8);
    await service.sync(ownerUserId: 'u1', familyId: 'f1');
    expect(requests, 9);
    await service.sync(ownerUserId: 'u1', familyId: 'f1');
    expect(requests, 9);
  });

  test('无 Bearer 的开发模式仍按 userId 隔离', () async {
    api.authToken = '';
    api.userId = 'u2';
    await ChatSyncService(
      api: api,
      store: store,
    ).sync(ownerUserId: 'u1', familyId: 'f1');
    expect(api.cursors, isEmpty);
    expect(store.messages, isEmpty);
  });

  test('数据库队列限定账号家庭和批量，退避上限持久写入', () async {
    final db = RecordingDatabase();
    final persistent = ChatLocalStore.withDatabase(db);
    await persistent.pendingAttachments(
      ownerUserId: 'u1',
      familyId: 'f1',
      now: now,
      limit: 1000,
    );
    expect(db.last!.namedArguments[#limit], 8);
    expect(db.last!.namedArguments[#whereArgs], [
      'u1',
      'f1',
      now.millisecondsSinceEpoch,
    ]);
    expect(
      db.last!.namedArguments[#where],
      contains('image_local_path IS NULL'),
    );
    await persistent.recordAttachmentAttempt(
      ownerUserId: 'u1',
      familyId: 'f1',
      serverId: 'm1',
      attempts: 100,
      now: now,
    );
    final values = db.last!.positionalArguments[1] as Map<String, Object?>;
    expect(values['image_retry_attempts'], 7);
    expect(
      values['image_retry_at'],
      now.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
    );
    expect(db.last!.namedArguments[#whereArgs], ['u1', 'f1', 'm1']);
  });
}
