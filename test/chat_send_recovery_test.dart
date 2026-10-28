import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/chat_local_store.dart';
import 'package:wo/data/chat_sync_service.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';

ChatLocalMessage outgoing({String owner = 'u1', String family = 'f1'}) =>
    ChatLocalMessage(
      clientId: 'same-client-id',
      ownerUserId: owner,
      familyId: family,
      senderId: owner,
      senderName: '我',
      senderEmoji: '👤',
      kind: 'text',
      body: '你好',
      status: chatStatusSending,
      createdAt: DateTime.utc(2026, 10, 1),
    );

ChatMessage receipt(ChatLocalMessage local) => ChatMessage.fromJson({
  'id': 'server-${local.ownerUserId}-${local.familyId}',
  'client_id': local.clientId,
  'family_id': local.familyId,
  'sender_id': local.ownerUserId,
  'sender_name': local.senderName,
  'sender_emoji': local.senderEmoji,
  'kind': 'text',
  'body': local.body,
  'created_at': local.createdAt.toUtc().toIso8601String(),
});

class MemoryStore implements ChatLocalStore {
  bool attachmentQueueFails = false;
  final rows = <(String, String, String), ChatLocalMessage>{};
  void add(ChatLocalMessage local) =>
      rows[(local.ownerUserId, local.familyId, local.clientId)] = local;
  ChatLocalMessage get first => rows.values.first;

  @override
  Future<List<ChatAttachmentRetry>> pendingAttachments({
    required String ownerUserId,
    required String familyId,
    required DateTime now,
    int limit = 8,
  }) async {
    if (attachmentQueueFails) throw StateError('attachment queue unavailable');
    return [];
  }

  @override
  Future<List<ChatLocalMessage>> pendingMessages({
    required String ownerUserId,
    required String familyId,
  }) async => rows.values
      .where(
        (m) =>
            m.ownerUserId == ownerUserId &&
            m.familyId == familyId &&
            m.status == chatStatusSending &&
            m.serverId == null,
      )
      .toList();

  @override
  Future<ChatLocalMessage?> byClientId({
    required String ownerUserId,
    required String familyId,
    required String clientId,
  }) async => rows[(ownerUserId, familyId, clientId)];

  @override
  Future<void> markStatus({
    required String ownerUserId,
    required String familyId,
    required String clientId,
    required String status,
  }) async {
    final key = (ownerUserId, familyId, clientId);
    final row = rows[key];
    if (row != null && row.serverId == null && row.status != chatStatusSent) {
      rows[key] = row.copyWith(status: status);
    }
  }

  @override
  Future<void> upsertRemote({
    required String ownerUserId,
    required ChatMessage remote,
    String? imageLocalPath,
  }) async {
    final key = (ownerUserId, remote.familyId, remote.clientId);
    rows[key] = rows[key]!.copyWith(
      serverId: remote.id,
      status: chatStatusSent,
    );
  }

  @override
  Future<ChatSyncState> syncState({
    required String ownerUserId,
    required String familyId,
  }) async => const ChatSyncState();

  @override
  Future<void> saveSyncState({
    required String ownerUserId,
    required String familyId,
    required DateTime afterCreatedAt,
    required String afterId,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeApi implements WoApi {
  @override
  String get authToken => 'test-token';
  @override
  String get userId => '';
  List<ChatMessage> remote = [];
  bool offline = false;
  int sends = 0;
  final sentIds = <String>[];
  Completer<ChatMessage>? response;
  final started = Completer<void>();

  @override
  Map<String, String> get imageHeaders => {};

  @override
  Future<
      ({
        List<ChatMessage> items,
        String? cursor,
        List<String>? activeMemberIds
      })> chatMessages(
    String familyId, {
    DateTime? afterCreatedAt,
    String? afterId,
    int limit = 100,
  }) async {
    if (offline) throw StateError('offline');
    return (items: remote, cursor: null, activeMemberIds: null);
  }

  @override
  Future<ChatMessage> sendChatText(
    String familyId, {
    required String clientId,
    required String body,
  }) async {
    sends++;
    sentIds.add(clientId);
    if (!started.isCompleted) started.complete();
    if (response != null) return response!.future;
    return receipt(outgoing(family: familyId));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late MemoryStore store;
  late FakeApi api;
  late ChatSyncService service;
  setUp(() {
    store = MemoryStore()..add(outgoing());
    api = FakeApi();
    service = ChatSyncService(api: api, store: store);
  });

  test('附件队列失败也完成发送恢复，重复同步共享完成结果', () async {
    store.attachmentQueueFails = true;
    final first = service.sync(ownerUserId: 'u1', familyId: 'f1');
    final duplicate = service.sync(ownerUserId: 'u1', familyId: 'f1');
    expect(identical(first, duplicate), true);
    await expectLater(first, throwsStateError);
    expect(store.first.status, chatStatusFailed);
    store.attachmentQueueFails = false;
    await service.sync(ownerUserId: 'u1', familyId: 'f1');
    expect(api.sends, 0);
  });

  test('进程在发送前退出：恢复为可重试，重试保留 client_id', () async {
    await service.sync(ownerUserId: 'u1', familyId: 'f1');
    expect(store.first.status, chatStatusFailed);
    expect(api.sends, 0);
    await service.sendPending(store.first);
    expect(api.sentIds, ['same-client-id']);
    expect(store.first.status, chatStatusSent);
  });

  test('服务端已接收后退出：同步归并回执，不重复发送', () async {
    final stale = store.first;
    api.remote = [receipt(stale)];
    await service.sync(ownerUserId: 'u1', familyId: 'f1');
    expect(store.rows.length, 1);
    expect(store.first.status, chatStatusSent);
    await service.sendPending(stale);
    expect(api.sends, 0);
  });

  test('离线恢复也解除永久 sending；失败消息不会自动重发', () async {
    api.offline = true;
    await expectLater(
      service.sync(ownerUserId: 'u1', familyId: 'f1'),
      throwsStateError,
    );
    expect(store.first.status, chatStatusFailed);
    api.offline = false;
    await service.sync(ownerUserId: 'u1', familyId: 'f1');
    expect(store.first.status, chatStatusFailed);
    expect(api.sends, 0);
  });

  test('活跃发送不会被恢复误判，跨 service 重复点击共用同一请求', () async {
    api.response = Completer<ChatMessage>();
    final first = service.sendPending(store.first);
    await api.started.future;
    final second = ChatSyncService(
      api: api,
      store: store,
    ).sendPending(store.first);
    await service.sync(ownerUserId: 'u1', familyId: 'f1');
    expect(store.first.status, chatStatusSending);
    expect(api.sends, 1);
    api.response!.complete(receipt(store.first));
    await Future.wait([first, second]);
    expect(store.first.status, chatStatusSent);
  });

  test('同步先确认回执，发送请求随后超时不能降级 sent', () async {
    api.response = Completer<ChatMessage>();
    final sending = service.sendPending(store.first);
    final assertion = expectLater(sending, throwsStateError);
    await api.started.future;
    api.remote = [receipt(store.first)];
    await service.sync(ownerUserId: 'u1', familyId: 'f1');
    api.response!.completeError(StateError('timeout after acceptance'));
    await assertion;
    expect(store.first.status, chatStatusSent);
  });

  test('恢复和新 service 重建按用户、家庭隔离', () async {
    store.add(outgoing(owner: 'u2'));
    store.add(outgoing(family: 'f2'));
    await service.sync(ownerUserId: 'u1', familyId: 'f1');
    expect(
      store.rows[('u1', 'f1', 'same-client-id')]!.status,
      chatStatusFailed,
    );
    expect(
      store.rows[('u2', 'f1', 'same-client-id')]!.status,
      chatStatusSending,
    );
    expect(
      store.rows[('u1', 'f2', 'same-client-id')]!.status,
      chatStatusSending,
    );
    await ChatSyncService(
      api: api,
      store: store,
    ).sync(ownerUserId: 'u1', familyId: 'f1');
    expect(api.sends, 0);
  });

  test('图片文件丢失时保留原消息并进入可重试状态', () async {
    final image = store.first.copyWith(
      kind: 'image',
      imageLocalPath: '/missing-chat-recovery-test/image.jpg',
    );
    store.add(image);
    await service.sync(ownerUserId: 'u1', familyId: 'f1');
    await expectLater(service.sendPending(image), throwsStateError);
    expect(store.first.clientId, image.clientId);
    expect(store.first.status, chatStatusFailed);
    expect(api.sends, 0);
  });

  test('账户或家庭已切换时，旧页面不再发出请求', () async {
    await service.sendPending(store.first, isCurrentScope: () => false);
    await service.sync(
      ownerUserId: 'u1',
      familyId: 'f1',
      isCurrentScope: () => false,
    );
    expect(api.sends, 0);
    expect(store.first.status, chatStatusFailed);
  });
}
