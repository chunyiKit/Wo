import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/models.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/features/plugins/memory/memory_save_draft.dart';

class _Api extends WoApi {
  _Api() : super(ApiClient());
  final Map<String, Memory> savedMemories = {};
  final Map<String, MemoryMedia> media = {};
  final List<String> attempts = [];
  bool loseCreateResponse = false;
  String? loseMediaResponse;
  String? failMedia;
  Completer<void>? blockCreate;
  void Function()? afterUpload;

  @override
  Future<Memory> createMemory(
    String familyId, {
    required String title,
    String? clientId,
    String? body,
    String? mood,
    String? location,
    String visibility = 'family',
    required DateTime eventDate,
  }) async {
    if (blockCreate != null) await blockCreate!.future;
    final result = savedMemories.putIfAbsent(
      clientId!,
      () => Memory.fromJson({
        'id': clientId,
        'family_id': familyId,
        'title': title,
        'event_date': eventDate.toIso8601String(),
      }),
    );
    if (loseCreateResponse) {
      loseCreateResponse = false;
      throw NetworkException('响应丢失');
    }
    return result;
  }

  @override
  Future<Memory> updateMemory(
    String familyId,
    String id, {
    required String title,
    String? body,
    String? mood,
    String? location,
    required String visibility,
    required DateTime eventDate,
  }) async =>
      savedMemories[id] ??
      Memory.fromJson({
        'id': id,
        'family_id': familyId,
        'title': title,
        'event_date': eventDate.toIso8601String(),
      });

  @override
  Future<MemoryMedia> uploadMemoryMedia(
    String familyId,
    String memoryId, {
    required List<int> bytes,
    required String filename,
    int? durationMs,
    String? clientId,
  }) async {
    attempts.add(clientId!);
    if (failMedia == clientId) throw NetworkException('断网');
    final result = media.putIfAbsent(
      clientId,
      () => MemoryMedia.fromJson({
        'id': clientId,
        'memory_id': memoryId,
        'kind': 'photo',
        'url': '/raw',
        'content_type': 'image/jpeg',
        'size_bytes': bytes.length,
        'sort_order': media.length,
      }),
    );
    afterUpload?.call();
    if (loseMediaResponse == clientId) {
      loseMediaResponse = null;
      throw NetworkException('响应丢失');
    }
    return result;
  }

  @override
  Future<void> deleteMemoryMedia(
    String familyId,
    String memoryId,
    String mediaId,
  ) async {
    if (media.remove(mediaId) == null) {
      throw ApiException('NOT_FOUND', '不存在', statusCode: 404);
    }
  }
}

MemorySaveDraft _draft() => MemorySaveDraft()
  ..fields = {
    'title': '回忆',
    'body': '',
    'mood': '',
    'location': '',
    'visibility': 'family',
    'event_date': '2026-10-12',
  }
  ..attachments.addAll([
    MemoryDraftAttachment(
      bytes: Uint8List.fromList([1]),
      filename: 'photo.jpg',
    ),
    MemoryDraftAttachment(
      bytes: Uint8List.fromList([2]),
      filename: 'video.mp4',
      durationMs: 500,
    ),
  ]);

void main() {
  late Directory dir;
  late MemoryDraftStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('memory-draft-test');
    store = MemoryDraftStore(Directory('${dir.path}/draft'));
  });
  tearDown(() async => dir.delete(recursive: true));

  test('创建响应丢失后重启仍复用同一回忆 ID', () async {
    final api = _Api()..loseCreateResponse = true;
    final draft = _draft();
    await expectLater(
      draft.save(api, 'family', store),
      throwsA(isA<NetworkException>()),
    );
    final restored = (await store.read())!;
    expect(restored.clientId, draft.clientId);
    expect(restored.memoryId, isNull);
    expect(await restored.save(api, 'family', store), isTrue);
    expect(api.savedMemories, hasLength(1));
    expect(api.media, hasLength(2));
    expect(await store.read(), isNull);
  });

  test('部分上传失败后恢复只上传剩余附件', () async {
    final draft = _draft();
    final api = _Api()..failMedia = draft.attachments.last.id;
    await expectLater(
      draft.save(api, 'family', store),
      throwsA(isA<NetworkException>()),
    );
    final restored = (await store.read())!;
    expect(restored.memoryId, draft.memoryId);
    expect(restored.attachments.first.uploaded, isTrue);
    expect(restored.attachments.last.durationMs, 500);
    api.failMedia = null;
    await restored.save(api, 'family', store);
    expect(
      api.attempts.where((id) => id == draft.attachments.first.id),
      hasLength(1),
    );
    expect(api.media, hasLength(2));
  });

  test('附件响应丢失重试不重复媒体', () async {
    final draft = _draft();
    final api = _Api()..loseMediaResponse = draft.attachments.last.id;
    await expectLater(
      draft.save(api, 'family', store),
      throwsA(isA<NetworkException>()),
    );
    await (await store.read())!.save(api, 'family', store);
    expect(api.media, hasLength(2));
    expect(api.savedMemories, hasLength(1));
  });

  test('移除响应丢失的附件后重试会删除其服务端副本', () async {
    final draft = _draft();
    final removedId = draft.attachments.last.id;
    final api = _Api()..loseMediaResponse = removedId;
    await expectLater(
      draft.save(api, 'family', store),
      throwsA(isA<NetworkException>()),
    );
    final restored = (await store.read())!;
    restored.attachments.removeLast();
    restored.removedMediaIds.add(removedId);
    await restored.save(api, 'family', store);
    expect(api.media, hasLength(1));
    expect(api.media.containsKey(removedId), isFalse);
  });

  test('连续点击保存只执行一个请求序列', () async {
    final draft = _draft();
    final gate = Completer<void>();
    final api = _Api()..blockCreate = gate;
    final first = draft.save(api, 'family', store);
    expect(await draft.save(api, 'family', store), isFalse);
    gate.complete();
    expect(await first, isTrue);
    expect(api.attempts, hasLength(2));
  });

  test('编辑保存保留原 ID 且重复删除 404 可以继续', () async {
    final draft = _draft();
    draft.memoryId = 'existing';
    draft.removedMediaIds.add('already-deleted');
    final api = _Api();
    await draft.save(api, 'family', store);
    expect(api.savedMemories, isEmpty);
    expect(api.media.values.every((m) => m.memoryId == 'existing'), isTrue);
  });

  test('上传中切换登录身份会停止下一次请求并保留草稿', () async {
    final draft = _draft();
    final api = _Api();
    api.afterUpload = () => api.authToken = 'another-account';
    await expectLater(
      draft.save(api, 'family', store),
      throwsA(isA<ApiException>()),
    );
    expect(api.attempts, hasLength(1));
    final restored = (await store.read())!;
    expect(restored.attachments.first.uploaded, isTrue);
    expect(restored.attachments.last.uploaded, isFalse);
  });

  test('上传中切换家庭会停止下一次请求并保留原草稿', () async {
    final draft = _draft();
    var sameScope = true;
    final api = _Api()..afterUpload = () => sameScope = false;
    await expectLater(
      draft.save(api, 'family', store, isScopeCurrent: () => sameScope),
      throwsA(isA<ApiException>()),
    );
    expect(api.attempts, hasLength(1));
    expect((await store.read())!.clientId, draft.clientId);
  });

  test('草稿隔离服务器、用户、家庭与编辑对象', () {
    final scopes = {
      MemoryDraftStore.scope('server', 'user', 'family', null),
      MemoryDraftStore.scope('other', 'user', 'family', null),
      MemoryDraftStore.scope('server', 'other', 'family', null),
      MemoryDraftStore.scope('server', 'user', 'other', null),
      MemoryDraftStore.scope('server', 'user', 'family', 'existing'),
    };
    expect(scopes, hasLength(5));
  });
}
