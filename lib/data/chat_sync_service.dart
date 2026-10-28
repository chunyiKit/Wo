import 'dart:io';

import 'package:http/http.dart' as http;

import 'chat_local_store.dart';
import 'models.dart';
import 'wo_api.dart';

class ChatSyncService {
  ChatSyncService({
    required this.api,
    ChatLocalStore? store,
    DateTime Function()? now,
    http.Client Function()? imageClientFactory,
  }) : store = store ?? ChatLocalStore.instance,
       _now = now ?? DateTime.now,
       _imageClientFactory = imageClientFactory ?? http.Client.new;

  final DateTime Function() _now;
  final http.Client Function() _imageClientFactory;
  final Map<(String, String), Future<void>> _syncs = {};

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
  }) {
    final key = (ownerUserId, familyId);
    return _syncs.putIfAbsent(
      key,
      () =>
          _sync(
            ownerUserId: ownerUserId,
            familyId: familyId,
            isCurrentScope: isCurrentScope,
          ).whenComplete(() {
            _syncs.remove(key);
          }),
    );
  }

  Future<void> _sync({
    required String ownerUserId,
    required String familyId,
    bool Function()? isCurrentScope,
  }) async {
    try {
      await _pull(
        ownerUserId: ownerUserId,
        familyId: familyId,
        isCurrentScope: isCurrentScope,
      );
    } finally {
      await _recoverInterrupted(ownerUserId, familyId);
    }
  }

  Future<void> _pull({
    required String ownerUserId,
    required String familyId,
    bool Function()? isCurrentScope,
  }) async {
    final token = api.authToken;
    // 正常登录仅设置 Bearer，X-User-Id 留空；开发模式才使用 userId。
    bool active() =>
        isCurrentScope?.call() != false &&
        api.authToken == token &&
        (token.isNotEmpty || api.userId == ownerUserId);
    if (!active()) return;
    var state = await store.syncState(
      ownerUserId: ownerUserId,
      familyId: familyId,
    );
    while (true) {
      if (!active()) return;
      final page = await api.chatMessages(
        familyId,
        afterCreatedAt: state.afterCreatedAt,
        afterId: state.afterId,
      );
      if (!active()) return;
      for (final remote in page.items) {
        if (!active()) return;
        if (remote.familyId != familyId) {
          throw StateError('聊天同步返回了其他家庭的数据');
        }
        // 先持久化元数据和缺失附件，再推进游标；下载失败不会丢失任务。
        await store.upsertRemote(ownerUserId: ownerUserId, remote: remote);
      }
      if (!active()) return;
      final activeMemberIds = page.activeMemberIds;
      if (activeMemberIds != null) {
        await store.anonymizeFormerSenders(
          ownerUserId: ownerUserId,
          familyId: familyId,
          activeMemberIds: activeMemberIds,
        );
      }
      if (!active() || page.items.isEmpty) break;
      final last = page.items.last;
      await store.saveSyncState(
        ownerUserId: ownerUserId,
        familyId: familyId,
        afterCreatedAt: last.createdAt,
        afterId: last.id,
      );
      state = ChatSyncState(afterCreatedAt: last.createdAt, afterId: last.id);
      if (page.items.length < 100) break;
    }
    // 只读取一批，失败后不在本次调用内循环重试；与消息游标完全独立。
    final pending = await store.pendingAttachments(
      ownerUserId: ownerUserId,
      familyId: familyId,
      now: _now(),
    );
    final budget = Stopwatch()..start();
    for (final retry in pending) {
      final remaining = const Duration(seconds: 5) - budget.elapsed;
      if (!active() || remaining <= Duration.zero) return;
      final message = retry.message;
      final image = ChatImage(
        messageId: message.serverId!,
        url: message.imageRemoteUrl!,
        contentType: message.imageContentType ?? 'image/jpeg',
        sizeBytes: message.imageSizeBytes ?? 0,
      );
      final imagePath = await _downloadImage(
        ownerUserId: ownerUserId,
        familyId: familyId,
        image: image,
        active: active,
        timeout: remaining,
      );
      if (!active()) return;
      await store.recordAttachmentAttempt(
        ownerUserId: ownerUserId,
        familyId: familyId,
        serverId: message.serverId!,
        attempts: retry.attempts,
        now: _now(),
        imageLocalPath: imagePath,
      );
    }
  }

  Future<void> sendPending(
    ChatLocalMessage local, {
    bool Function()? isCurrentScope,
  }) {
    final key = _key(local);
    return _sends[key] ??= _sendPending(local, isCurrentScope).whenComplete(() {
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

  Future<String?> _downloadImage({
    required String ownerUserId,
    required String familyId,
    required ChatImage image,
    required bool Function() active,
    required Duration timeout,
  }) async {
    http.Client? client;
    File? temporary;
    try {
      if (!active()) return null;
      final uri = Uri.parse(api.chatImageUrl(image));
      final headers = Map<String, String>.of(api.imageHeaders);
      final localPath = await store.imagePath(
        ownerUserId: ownerUserId,
        familyId: familyId,
        key: image.messageId,
        contentType: image.contentType,
      );
      if (!active()) return null;
      final file = File(localPath);
      if (await file.exists()) return localPath;
      client = _imageClientFactory();
      final res = await client.get(uri, headers: headers).timeout(timeout);
      if (!active() ||
          res.statusCode < 200 ||
          res.statusCode >= 300 ||
          res.bodyBytes.isEmpty)
        return null;
      await file.parent.create(recursive: true);
      // 中断写入不能留下一个被下次同步当作成功缓存的半文件。
      temporary = File('$localPath.part');
      await temporary.writeAsBytes(res.bodyBytes, flush: true);
      if (!active()) return null;
      await temporary.rename(localPath);
      return localPath;
    } catch (_) {
      return null;
    } finally {
      client?.close();
      if (temporary != null) {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {
          // 临时文件不会作为已完成附件使用。
        }
      }
    }
  }
}
