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

  Future<void> sync({
    required String ownerUserId,
    required String familyId,
  }) async {
    var state = await store.syncState(
      ownerUserId: ownerUserId,
      familyId: familyId,
    );
    while (true) {
      final page = await api.chatMessages(
        familyId,
        afterCreatedAt: state.afterCreatedAt,
        afterId: state.afterId,
      );
      if (page.items.isEmpty) return;
      for (final remote in page.items) {
        final imagePath = await _ensureImage(
          ownerUserId: ownerUserId,
          remote: remote,
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

  Future<void> sendPending(ChatLocalMessage local) async {
    await store.markStatus(
      ownerUserId: local.ownerUserId,
      familyId: local.familyId,
      clientId: local.clientId,
      status: chatStatusSending,
    );
    try {
      final ChatMessage remote;
      if (local.isImage) {
        final path = local.imageLocalPath;
        if (path == null || !await File(path).exists()) {
          throw StateError('图片文件不存在');
        }
        remote = await api.sendChatImage(
          local.familyId,
          clientId: local.clientId,
          bytes: await File(path).readAsBytes(),
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
        headers: api.imageHeaders,
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return existingPath;
      await file.parent.create(recursive: true);
      await file.writeAsBytes(Uint8List.fromList(res.bodyBytes), flush: true);
      return localPath;
    } catch (_) {
      return existingPath;
    }
  }
}
