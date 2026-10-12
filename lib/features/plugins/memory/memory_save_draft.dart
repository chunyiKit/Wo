import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_api.dart';

/// 保存前先落盘稳定的请求 ID；响应丢失时用同一个 ID 重试。
class MemoryDraftAttachment {
  MemoryDraftAttachment({
    required this.bytes,
    required this.filename,
    this.durationMs,
    String? id,
    this.uploaded = false,
  }) : id = id ?? const Uuid().v4();

  final String id;
  final Uint8List bytes;
  final String filename;
  final int? durationMs;
  bool uploaded;
}

class MemorySaveDraft {
  MemorySaveDraft({String? memoryId, String? clientId})
    : memoryId = memoryId,
      clientId = clientId ?? const Uuid().v4();

  final String clientId;
  String? memoryId;
  Map<String, dynamic> fields = {};
  List<MemoryMedia> existingMedia = [];
  final List<MemoryDraftAttachment> attachments = [];
  final Set<String> removedMediaIds = {};
  bool _saving = false;

  /// 同一草稿只运行一个保存；页面离开和进程重启后由文件恢复。
  Future<bool> save(
    WoApi api,
    String familyId,
    MemoryDraftStore store, {
    bool Function()? isScopeCurrent,
  }) async {
    if (_saving) return false;
    _saving = true;
    final token = api.authToken;
    final userId = api.userId;
    final server = api.baseUrl;
    void checkScope() {
      if (api.authToken != token ||
          api.userId != userId ||
          api.baseUrl != server ||
          !(isScopeCurrent?.call() ?? true)) {
        throw ApiException('SESSION_CHANGED', '登录身份或家庭已改变，请返回后重试');
      }
    }

    try {
      checkScope();
      await store.write(this);
      if (memoryId == null) {
        checkScope();
        final created = await api.createMemory(
          familyId,
          clientId: clientId,
          title: fields['title'] as String,
          body: fields['body'] as String?,
          mood: fields['mood'] as String?,
          location: fields['location'] as String?,
          visibility: fields['visibility'] as String,
          eventDate: DateTime.parse(fields['event_date'] as String),
        );
        memoryId = created.id;
        await store.write(this);
      }
      // 重放 create 可能返回第一次保存的内容，仍要应用用户重试前的修改。
      checkScope();
      await api.updateMemory(
        familyId,
        memoryId!,
        title: fields['title'] as String,
        body: fields['body'] as String?,
        mood: fields['mood'] as String?,
        location: fields['location'] as String?,
        visibility: fields['visibility'] as String,
        eventDate: DateTime.parse(fields['event_date'] as String),
      );
      for (final id in removedMediaIds.toList()) {
        try {
          checkScope();
          await api.deleteMemoryMedia(familyId, memoryId!, id);
        } on ApiException catch (e) {
          // 删除响应丢失后再次删除，404 即已完成。
          if (e.statusCode != 404) rethrow;
        }
        removedMediaIds.remove(id);
        await store.write(this);
      }
      for (final attachment in attachments) {
        if (attachment.uploaded) continue;
        checkScope();
        await api.uploadMemoryMedia(
          familyId,
          memoryId!,
          clientId: attachment.id,
          bytes: attachment.bytes,
          filename: attachment.filename,
          durationMs: attachment.durationMs,
        );
        attachment.uploaded = true;
        await store.write(this);
      }
      checkScope();
      await store.clear();
      return true;
    } finally {
      _saving = false;
    }
  }
}

/// 媒体单独存文件，保存进度只原子替换小型 manifest。
class MemoryDraftStore {
  MemoryDraftStore(this.directory);
  final Directory directory;

  static String scope(String server, String user, String family, String? id) =>
      const Uuid().v5(
        Namespace.url.value,
        jsonEncode([server, user, family, id]),
      );

  Future<void> write(MemorySaveDraft draft) async {
    await directory.create(recursive: true);
    for (final a in draft.attachments) {
      final file = File('${directory.path}/${a.id}.media');
      if (!await file.exists()) {
        final temp = File('${file.path}.tmp');
        await temp.writeAsBytes(a.bytes, flush: true);
        await temp.rename(file.path);
      }
    }
    final temp = File('${directory.path}/draft.tmp');
    await temp.writeAsString(
      jsonEncode({
        'client_id': draft.clientId,
        'memory_id': draft.memoryId,
        'fields': draft.fields,
        'existing_media': draft.existingMedia.map((m) => m.toJson()).toList(),
        'removed_media_ids': draft.removedMediaIds.toList(),
        'attachments': [
          for (final a in draft.attachments)
            {
              'id': a.id,
              'filename': a.filename,
              'duration_ms': a.durationMs,
              'uploaded': a.uploaded,
            },
        ],
      }),
      flush: true,
    );
    await temp.rename('${directory.path}/draft.json');
  }

  Future<MemorySaveDraft?> read() async {
    final file = File('${directory.path}/draft.json');
    if (!await file.exists()) return null;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final draft = MemorySaveDraft(
      memoryId: data['memory_id'] as String?,
      clientId: data['client_id'] as String,
    );
    draft.fields = Map<String, dynamic>.from(data['fields'] as Map);
    draft.existingMedia = (data['existing_media'] as List)
        .map((m) => MemoryMedia.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList();
    draft.removedMediaIds.addAll(
      (data['removed_media_ids'] as List).cast<String>(),
    );
    for (final item in data['attachments'] as List) {
      final a = Map<String, dynamic>.from(item as Map);
      draft.attachments.add(
        MemoryDraftAttachment(
          id: a['id'] as String,
          bytes: await File('${directory.path}/${a['id']}.media').readAsBytes(),
          filename: a['filename'] as String,
          durationMs: a['duration_ms'] as int?,
          uploaded: a['uploaded'] as bool,
        ),
      );
    }
    return draft;
  }

  Future<void> clear() async {
    // 先删 manifest，已完成草稿不再恢复。
    final manifest = File('${directory.path}/draft.json');
    if (await manifest.exists()) await manifest.delete();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
