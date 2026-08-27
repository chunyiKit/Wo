import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

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

class ChatLocalStore {
  ChatLocalStore._();

  static final ChatLocalStore instance = ChatLocalStore._();

  Database? _db;

  Future<Database> get _database async {
    final cached = _db;
    if (cached != null) return cached;
    final dbPath = await getDatabasesPath();
    final db = await openDatabase(
      path.join(dbPath, 'wo_chat.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
CREATE TABLE chat_messages (
  local_id INTEGER PRIMARY KEY AUTOINCREMENT,
  server_id TEXT UNIQUE,
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
  UNIQUE(owner_user_id, family_id, client_id)
)
''');
        await db.execute('''
CREATE INDEX ix_chat_messages_owner_family_created
ON chat_messages(owner_user_id, family_id, created_at, local_id)
''');
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

  Future<List<ChatLocalMessage>> listMessages({
    required String ownerUserId,
    required String familyId,
    int limit = 500,
  }) async {
    final db = await _database;
    final rows = await db.query(
      'chat_messages',
      where: 'owner_user_id = ? AND family_id = ?',
      whereArgs: [ownerUserId, familyId],
      orderBy: 'created_at ASC, local_id ASC',
      limit: limit,
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
      where: 'owner_user_id = ? AND family_id = ? AND client_id = ?',
      whereArgs: [ownerUserId, familyId, clientId],
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
    final existing = existingByServer ??
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
