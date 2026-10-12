import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'chat_message_query.dart';
import 'models.dart';

const chatStatusSending = 'sending';
const chatStatusSent = 'sent';
const chatStatusFailed = 'failed';

class ChatSyncState {
  const ChatSyncState({this.afterCreatedAt, this.afterId});

  final DateTime? afterCreatedAt;
  final String? afterId;
}

class ChatLocalMessage {
  const ChatLocalMessage({
    this.localId,
    this.serverId,
    required this.clientId,
    required this.ownerUserId,
    required this.familyId,
    this.senderId,
    required this.senderName,
    required this.senderEmoji,
    this.senderAvatarUrl,
    required this.kind,
    this.body,
    required this.status,
    required this.createdAt,
    this.imageLocalPath,
    this.imageRemoteUrl,
    this.imageContentType,
    this.imageSizeBytes,
    this.imageWidth,
    this.imageHeight,
  });

  final int? localId;
  final String? serverId;
  final String clientId;
  final String ownerUserId;
  final String familyId;
  final String? senderId;
  final String senderName;
  final String senderEmoji;
  final String? senderAvatarUrl;
  final String kind;
  final String? body;
  final String status;
  final DateTime createdAt;
  final String? imageLocalPath;
  final String? imageRemoteUrl;
  final String? imageContentType;
  final int? imageSizeBytes;
  final int? imageWidth;
  final int? imageHeight;

  bool get isMine => senderId == ownerUserId || senderId == null;
  bool get isImage => kind == 'image';

  ChatLocalMessage copyWith({
    int? localId,
    String? serverId,
    String? clientId,
    String? ownerUserId,
    String? familyId,
    String? senderId,
    String? senderName,
    String? senderEmoji,
    String? senderAvatarUrl,
    String? kind,
    String? body,
    String? status,
    DateTime? createdAt,
    String? imageLocalPath,
    String? imageRemoteUrl,
    String? imageContentType,
    int? imageSizeBytes,
    int? imageWidth,
    int? imageHeight,
  }) =>
      ChatLocalMessage(
        localId: localId ?? this.localId,
        serverId: serverId ?? this.serverId,
        clientId: clientId ?? this.clientId,
        ownerUserId: ownerUserId ?? this.ownerUserId,
        familyId: familyId ?? this.familyId,
        senderId: senderId ?? this.senderId,
        senderName: senderName ?? this.senderName,
        senderEmoji: senderEmoji ?? this.senderEmoji,
        senderAvatarUrl: senderAvatarUrl ?? this.senderAvatarUrl,
        kind: kind ?? this.kind,
        body: body ?? this.body,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
        imageLocalPath: imageLocalPath ?? this.imageLocalPath,
        imageRemoteUrl: imageRemoteUrl ?? this.imageRemoteUrl,
        imageContentType: imageContentType ?? this.imageContentType,
        imageSizeBytes: imageSizeBytes ?? this.imageSizeBytes,
        imageWidth: imageWidth ?? this.imageWidth,
        imageHeight: imageHeight ?? this.imageHeight,
      );

  Map<String, Object?> toDb() => {
        'local_id': localId,
        'server_id': serverId,
        'client_id': clientId,
        'owner_user_id': ownerUserId,
        'family_id': familyId,
        'sender_id': senderId,
        'sender_name': senderName,
        'sender_emoji': senderEmoji,
        'sender_avatar_url': senderAvatarUrl,
        'kind': kind,
        'body': body,
        'status': status,
        'created_at': createdAt.toUtc().toIso8601String(),
        'image_local_path': imageLocalPath,
        'image_remote_url': imageRemoteUrl,
        'image_content_type': imageContentType,
        'image_size_bytes': imageSizeBytes,
        'image_width': imageWidth,
        'image_height': imageHeight,
      };

  factory ChatLocalMessage.fromDb(Map<String, Object?> row) => ChatLocalMessage(
        localId: (row['local_id'] as num?)?.toInt(),
        serverId: row['server_id'] as String?,
        clientId: row['client_id'] as String? ?? '',
        ownerUserId: row['owner_user_id'] as String? ?? '',
        familyId: row['family_id'] as String? ?? '',
        senderId: row['sender_id'] as String?,
        senderName: row['sender_name'] as String? ?? '',
        senderEmoji: row['sender_emoji'] as String? ?? '👤',
        senderAvatarUrl: row['sender_avatar_url'] as String?,
        kind: row['kind'] as String? ?? 'text',
        body: row['body'] as String?,
        status: row['status'] as String? ?? chatStatusSent,
        createdAt:
            DateTime.tryParse(row['created_at']?.toString() ?? '')?.toLocal() ??
                DateTime.now(),
        imageLocalPath: row['image_local_path'] as String?,
        imageRemoteUrl: row['image_remote_url'] as String?,
        imageContentType: row['image_content_type'] as String?,
        imageSizeBytes: (row['image_size_bytes'] as num?)?.toInt(),
        imageWidth: (row['image_width'] as num?)?.toInt(),
        imageHeight: (row['image_height'] as num?)?.toInt(),
      );
}

class ChatAttachmentRetry {
  const ChatAttachmentRetry({required this.message, required this.attempts});

  final ChatLocalMessage message;
  final int attempts;
}

class ChatLocalStore {
  ChatLocalStore._();

  /// 使用调用方提供的数据库，便于离线验证迁移和持久化行为。
  ChatLocalStore.withDatabase(Database database) : _db = database;

  static final ChatLocalStore instance = ChatLocalStore._();

  Database? _db;

  Future<Database> get _database async {
    final cached = _db;
    if (cached != null) return cached;
    final dbPath = await getDatabasesPath();
    final db = await openDatabase(
      path.join(dbPath, 'wo_chat.db'),
      version: 2,
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          // sqflite 在升级事务内执行；保留 local_id、消息及同步游标。
          // SQLite 无法直接删除旧的 server_id 全局 UNIQUE，重建为账号/家庭约束。
          await db.execute(
            'ALTER TABLE chat_messages RENAME TO chat_messages_v1',
          );
          await db.execute('DROP INDEX ix_chat_messages_owner_family_created');
          await _createMessagesTable(db);
          await db.execute(
            '''INSERT INTO chat_messages (local_id, server_id, client_id, owner_user_id, family_id, sender_id, sender_name, sender_emoji, sender_avatar_url, kind, body, status, created_at, image_local_path, image_remote_url, image_content_type, image_size_bytes, image_width, image_height)
SELECT local_id, server_id, client_id, owner_user_id, family_id, sender_id, sender_name, sender_emoji, sender_avatar_url, kind, body, status, created_at, image_local_path, image_remote_url, image_content_type, image_size_bytes, image_width, image_height FROM chat_messages_v1''',
          );
          await db.execute('DROP TABLE chat_messages_v1');
        }
      },
      onCreate: (db, _) async {
        await _createMessagesTable(db);
        await db.execute('''
CREATE TABLE chat_sync_state (
  owner_user_id TEXT NOT NULL,
  family_id TEXT NOT NULL,
  after_created_at TEXT,
  after_id TEXT,
  last_opened_at TEXT,
  PRIMARY KEY(owner_user_id, family_id)
)
''');
      },
    );
    _db = db;
    return db;
  }

  static Future<void> _createMessagesTable(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE chat_messages (
  local_id INTEGER PRIMARY KEY AUTOINCREMENT,
  server_id TEXT,
  client_id TEXT NOT NULL,
  owner_user_id TEXT NOT NULL,
  family_id TEXT NOT NULL,
  sender_id TEXT,
  sender_name TEXT NOT NULL,
  sender_emoji TEXT NOT NULL,
  sender_avatar_url TEXT,
  kind TEXT NOT NULL,
  body TEXT,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  image_local_path TEXT,
  image_remote_url TEXT,
  image_content_type TEXT,
  image_size_bytes INTEGER,
  image_width INTEGER,
  image_height INTEGER,
  image_retry_attempts INTEGER NOT NULL DEFAULT 0,
  image_retry_at INTEGER NOT NULL DEFAULT 0,
  UNIQUE(owner_user_id, family_id, server_id),
  UNIQUE(owner_user_id, family_id, client_id)
)
''');
    await db.execute('''
CREATE INDEX ix_chat_messages_owner_family_created
ON chat_messages(owner_user_id, family_id, created_at, local_id)
''');
  }

  /// 缺失附件本身就是持久队列；升级前已越过游标的失败图片也会被补齐。
  Future<List<ChatAttachmentRetry>> pendingAttachments({
    required String ownerUserId,
    required String familyId,
    required DateTime now,
    int limit = 8,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'chat_messages',
      where:
          'owner_user_id = ? AND family_id = ? AND server_id IS NOT NULL '
          'AND image_remote_url IS NOT NULL AND image_local_path IS NULL '
          'AND image_retry_at <= ?',
      whereArgs: [ownerUserId, familyId, now.millisecondsSinceEpoch],
      orderBy: 'image_retry_at ASC, local_id ASC',
      limit: limit.clamp(1, 8),
    );
    return rows
        .map(
          (row) => ChatAttachmentRetry(
            message: ChatLocalMessage.fromDb(row),
            attempts: (row['image_retry_attempts'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList();
  }

  Future<void> recordAttachmentAttempt({
    required String ownerUserId,
    required String familyId,
    required String serverId,
    required int attempts,
    required DateTime now,
    String? imageLocalPath,
  }) async {
    final db = await _database;
    // 30 秒起步，最多 30 分钟。保留失败记录，下一次前台同步继续尝试。
    final delaySeconds = (30 * (1 << attempts.clamp(0, 6))).clamp(30, 1800);
    await db.update(
      'chat_messages',
      {
        if (imageLocalPath != null) 'image_local_path': imageLocalPath,
        'image_retry_attempts': imageLocalPath == null
            ? (attempts + 1).clamp(0, 7)
            : 0,
        'image_retry_at': imageLocalPath == null
            ? now.add(Duration(seconds: delaySeconds)).millisecondsSinceEpoch
            : 0,
      },
      where:
          'owner_user_id = ? AND family_id = ? AND server_id = ? '
          'AND image_local_path IS NULL',
      whereArgs: [ownerUserId, familyId, serverId],
    );
  }

  Future<List<ChatLocalMessage>> listMessages({
    required String ownerUserId,
    required String familyId,
    int? limit = 500,
    ChatMessageCursor? before,
    ChatMessageCursor? from,
    List<int> retainedLocalIds = const [],
  }) async {
    final query = ChatMessageQuery(
      ownerUserId: ownerUserId,
      familyId: familyId,
      before: before,
      from: from,
      retainedLocalIds: retainedLocalIds,
      limit: limit,
    );
    final db = await _database;
    final rows = await db.query(
      'chat_messages',
      where: query.where,
      whereArgs: query.whereArgs,
      orderBy: ChatMessageQuery.orderBy,
      limit: query.limit,
    );
    // SQL 先截取最新窗口，展示仍保持从旧到新。
    return rows.reversed.map(ChatLocalMessage.fromDb).toList();
  }

  /// 不受历史列表分页上限影响，仅恢复当前用户、当前家庭的待发送消息。
  Future<List<ChatLocalMessage>> pendingMessages({
    required String ownerUserId,
    required String familyId,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'chat_messages',
      where:
          'owner_user_id = ? AND family_id = ? AND status = ? '
          'AND server_id IS NULL',
      whereArgs: [ownerUserId, familyId, chatStatusSending],
    );
    return rows.map(ChatLocalMessage.fromDb).toList();
  }

  Future<ChatLocalMessage?> byClientId({
    required String ownerUserId,
    required String familyId,
    required String clientId,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'chat_messages',
      where: 'owner_user_id = ? AND family_id = ? AND client_id = ?',
      whereArgs: [ownerUserId, familyId, clientId],
      limit: 1,
    );
    return rows.isEmpty ? null : ChatLocalMessage.fromDb(rows.first);
  }

  Future<ChatLocalMessage?> byServerId({
    required String ownerUserId,
    required String familyId,
    required String serverId,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'chat_messages',
      where: 'owner_user_id = ? AND family_id = ? AND server_id = ?',
      whereArgs: [ownerUserId, familyId, serverId],
      limit: 1,
    );
    return rows.isEmpty ? null : ChatLocalMessage.fromDb(rows.first);
  }

  Future<ChatLocalMessage> insertOutgoingText({
    required String ownerUserId,
    required String familyId,
    required String clientId,
    required String senderName,
    required String senderEmoji,
    String? senderAvatarUrl,
    required String body,
  }) async {
    final message = ChatLocalMessage(
      clientId: clientId,
      ownerUserId: ownerUserId,
      familyId: familyId,
      senderId: ownerUserId,
      senderName: senderName,
      senderEmoji: senderEmoji,
      senderAvatarUrl: senderAvatarUrl,
      kind: 'text',
      body: body,
      status: chatStatusSending,
      createdAt: DateTime.now(),
    );
    final db = await _database;
    final id = await db.insert(
      'chat_messages',
      message.toDb(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return message.copyWith(localId: id);
  }

  Future<ChatLocalMessage> insertOutgoingImage({
    required String ownerUserId,
    required String familyId,
    required String clientId,
    required String senderName,
    required String senderEmoji,
    String? senderAvatarUrl,
    String? body,
    required String imageLocalPath,
    required int imageSizeBytes,
  }) async {
    final message = ChatLocalMessage(
      clientId: clientId,
      ownerUserId: ownerUserId,
      familyId: familyId,
      senderId: ownerUserId,
      senderName: senderName,
      senderEmoji: senderEmoji,
      senderAvatarUrl: senderAvatarUrl,
      kind: 'image',
      body: body,
      status: chatStatusSending,
      createdAt: DateTime.now(),
      imageLocalPath: imageLocalPath,
      imageContentType: 'image/jpeg',
      imageSizeBytes: imageSizeBytes,
    );
    final db = await _database;
    final id = await db.insert(
      'chat_messages',
      message.toDb(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return message.copyWith(localId: id);
  }

  Future<void> markStatus({
    required String ownerUserId,
    required String familyId,
    required String clientId,
    required String status,
  }) async {
    final db = await _database;
    await db.update(
      'chat_messages',
      {'status': status},
      // 服务端回执是最终状态；迟到的超时或恢复操作不能将其降级。
      where:
          'owner_user_id = ? AND family_id = ? AND client_id = ? '
          'AND server_id IS NULL AND status != ?',
      whereArgs: [ownerUserId, familyId, clientId, chatStatusSent],
    );
  }

  Future<void> upsertRemote({
    required String ownerUserId,
    required ChatMessage remote,
    String? imageLocalPath,
  }) async {
    final existingByServer = await byServerId(
      ownerUserId: ownerUserId,
      familyId: remote.familyId,
      serverId: remote.id,
    );
    final existing =
        existingByServer ??
        await byClientId(
          ownerUserId: ownerUserId,
          familyId: remote.familyId,
          clientId: remote.clientId,
        );
    final img = remote.image;
    final local = ChatLocalMessage(
      localId: existing?.localId,
      serverId: remote.id,
      clientId: remote.clientId,
      ownerUserId: ownerUserId,
      familyId: remote.familyId,
      senderId: remote.senderId,
      senderName: remote.senderName,
      senderEmoji: remote.senderEmoji,
      senderAvatarUrl: remote.senderAvatarUrl,
      kind: remote.kind,
      body: remote.body,
      status: chatStatusSent,
      createdAt: remote.createdAt,
      imageLocalPath: imageLocalPath ?? existing?.imageLocalPath,
      imageRemoteUrl: img?.url,
      imageContentType: img?.contentType ?? existing?.imageContentType,
      imageSizeBytes: img?.sizeBytes ?? existing?.imageSizeBytes,
      imageWidth: img?.width ?? existing?.imageWidth,
      imageHeight: img?.height ?? existing?.imageHeight,
    );
    final db = await _database;
    if (existing == null) {
      await db.insert('chat_messages', local.toDb());
    } else {
      await db.update(
        'chat_messages',
        local.toDb(),
        where: 'local_id = ?',
        whereArgs: [existing.localId],
      );
    }
  }

  Future<ChatSyncState> syncState({
    required String ownerUserId,
    required String familyId,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'chat_sync_state',
      where: 'owner_user_id = ? AND family_id = ?',
      whereArgs: [ownerUserId, familyId],
      limit: 1,
    );
    if (rows.isEmpty) return const ChatSyncState();
    final row = rows.first;
    return ChatSyncState(
      afterCreatedAt:
          DateTime.tryParse(row['after_created_at']?.toString() ?? '')
              ?.toLocal(),
      afterId: row['after_id'] as String?,
    );
  }

  Future<void> saveSyncState({
    required String ownerUserId,
    required String familyId,
    required DateTime afterCreatedAt,
    required String afterId,
  }) async {
    final db = await _database;
    await db.insert(
      'chat_sync_state',
      {
        'owner_user_id': ownerUserId,
        'family_id': familyId,
        'after_created_at': afterCreatedAt.toUtc().toIso8601String(),
        'after_id': afterId,
        'last_opened_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> writeImageBytes({
    required String ownerUserId,
    required String familyId,
    required String key,
    required Uint8List bytes,
    String contentType = 'image/jpeg',
  }) async {
    final file = File(
      await imagePath(
        ownerUserId: ownerUserId,
        familyId: familyId,
        key: key,
        contentType: contentType,
      ),
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<String> imagePath({
    required String ownerUserId,
    required String familyId,
    required String key,
    required String contentType,
  }) async {
    final dir = await getApplicationSupportDirectory();
    final ext = contentType.contains('png') ? 'png' : 'jpg';
    return path.join(
      dir.path,
      'chat',
      _safe(ownerUserId),
      _safe(familyId),
      '${_safe(key)}.$ext',
    );
  }

  String _safe(String value) =>
      value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
}
