import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'chat_local_store.dart';
import 'models.dart';
import 'wo_api.dart';

class ChatSyncService {
  ChatSyncService({required this.api, ChatLocalStore? store})
    : store = store ?? ChatLocalStore.instance;

  final WoApi api;
  final ChatLocalStore store;

  // 页面重建也共享进行中请求，恢复操作不能把活跃发送误判为中断。
  static final _sends = <(String, String, String), Future<void>>{};
  static final _recoveries = <(String, String, String), Future<void>>{};

  (String, String, String) _key(ChatLocalMessage local) =>
      (local.ownerUserId, local.familyId, local.clientId);

  Future<void> _recoverInterrupted(String ownerUserId, String familyId) async {
    final pending = await store.pendingMessages(
      ownerUserId: ownerUserId,
      familyId: familyId,
    );
    for (final local in pending) {
      final key = _key(local);
      if (_sends.containsKey(key) || _recoveries.containsKey(key)) continue;
      final recovery = store.markStatus(
        ownerUserId: ownerUserId,
        familyId: familyId,
        clientId: local.clientId,
        status: chatStatusFailed,
      );
      _recoveries[key] = recovery;
      try {
        await recovery;
      } finally {
        _recoveries.remove(key);
      }
    }
  }

  Future<void> sync({
    required String ownerUserId,
    required String familyId,
    bool Function()? isCurrentScope,
  }) async {
    // 优先归并已被服务端接收的消息；离线时也必须解除永久 sending。
    try {
      await _pull(ownerUserId, familyId, isCurrentScope);
    } finally {
      await _recoverInterrupted(ownerUserId, familyId);
    }
  }

  Future<void> _pull(
    String ownerUserId,
    String familyId,
    bool Function()? isCurrentScope,
  ) async {
    final imageHeaders = api.imageHeaders;
    var state = await store.syncState(
      ownerUserId: ownerUserId,
      familyId: familyId,
    );
    while (true) {
      if (isCurrentScope?.call() == false) return;
      final page = await api.chatMessages(
        familyId,
        afterCreatedAt: state.afterCreatedAt,
        afterId: state.afterId,
      );
      if (isCurrentScope?.call() == false) return;
      if (page.items.isEmpty) return;
      for (final remote in page.items) {
        if (isCurrentScope?.call() == false) return;
        final imagePath = await _ensureImage(
          ownerUserId: ownerUserId,
          remote: remote,
          headers: imageHeaders,
        );
        await store.upsertRemote(
          ownerUserId: ownerUserId,
          remote: remote,
          imageLocalPath: imagePath,
        );
      }
      final last = page.items.last;
      await store.saveSyncState(
        ownerUserId: ownerUserId,
        familyId: familyId,
        afterCreatedAt: last.createdAt,
        afterId: last.id,
      );
      state = ChatSyncState(afterCreatedAt: last.createdAt, afterId: last.id);
      if (page.items.length < 100) return;
    }
  }

  Future<void> sendPending(
    ChatLocalMessage local, {
    bool Function()? isCurrentScope,
  }) {
    final key = _key(local);
    return _sends[key] ??= _sendPending(
      local,
      isCurrentScope,
    ).whenComplete(() {
          _sends.remove(key);
        });
  }

  Future<void> _sendPending(
    ChatLocalMessage local,
    bool Function()? isCurrentScope,
  ) async {
    await _recoveries[_key(local)];
    // 重试可能持有过期的 UI 对象，必须重新读取已归并的本地状态。
    final latest = await store.byClientId(
      ownerUserId: local.ownerUserId,
      familyId: local.familyId,
      clientId: local.clientId,
    );
    if (latest == null ||
        latest.serverId != null ||
        latest.status == chatStatusSent)
      return;
    local = latest;
    if (isCurrentScope?.call() == false) return;
    await store.markStatus(
      ownerUserId: local.ownerUserId,
      familyId: local.familyId,
      clientId: local.clientId,
      status: chatStatusSending,
    );
    try {
      if (isCurrentScope?.call() == false) return;
      final ChatMessage remote;
      if (local.isImage) {
        final path = local.imageLocalPath;
        if (path == null || !await File(path).exists()) {
          throw StateError('图片文件不存在');
        }
        final bytes = await File(path).readAsBytes();
        if (isCurrentScope?.call() == false) return;
        remote = await api.sendChatImage(
          local.familyId,
          clientId: local.clientId,
          bytes: bytes,
          body: local.body,
        );
        await store.upsertRemote(
          ownerUserId: local.ownerUserId,
          remote: remote,
          imageLocalPath: path,
        );
      } else {
        remote = await api.sendChatText(
          local.familyId,
          clientId: local.clientId,
          body: local.body ?? '',
        );
        await store.upsertRemote(
          ownerUserId: local.ownerUserId,
          remote: remote,
        );
      }
    } catch (_) {
      await store.markStatus(
        ownerUserId: local.ownerUserId,
        familyId: local.familyId,
        clientId: local.clientId,
        status: chatStatusFailed,
      );
      rethrow;
    }
  }

  Future<String?> _ensureImage({
    required String ownerUserId,
    required ChatMessage remote,
    required Map<String, String> headers,
  }) async {
    final image = remote.image;
    if (image == null) return null;

    final existing = await store.byServerId(
      ownerUserId: ownerUserId,
      familyId: remote.familyId,
      serverId: remote.id,
    );
    final existingPath = existing?.imageLocalPath;
    if (existingPath != null && await File(existingPath).exists()) {
      return existingPath;
    }

    final localPath = await store.imagePath(
      ownerUserId: ownerUserId,
      familyId: remote.familyId,
      key: remote.id,
      contentType: image.contentType,
    );
    final file = File(localPath);
    if (await file.exists()) return localPath;

    try {
      final res = await http.get(
        Uri.parse(api.chatImageUrl(image)),
        headers: headers,
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode >= 300) return existingPath;
      await file.parent.create(recursive: true);
      await file.writeAsBytes(Uint8List.fromList(res.bodyBytes), flush: true);
      return localPath;
    } catch (_) {
      return existingPath;
    }
  }
}
