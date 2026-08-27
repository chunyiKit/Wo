import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/chat_local_store.dart';
import 'package:wo/data/models.dart';

void main() {
  test('ChatMessage parses image payload and sender avatar', () {
    final message = ChatMessage.fromJson({
      'id': 'm1',
      'family_id': 'f1',
      'sender_id': 'u1',
      'client_id': 'c1',
      'kind': 'image',
      'body': '看图',
      'sender_name': '妈妈',
      'sender_emoji': '👩',
      'sender_avatar_url': '/api/v1/families/f1/members/u1/avatar?v=2',
      'created_at': '2026-06-25T10:00:00Z',
      'image': {
        'message_id': 'm1',
        'url': '/api/v1/families/f1/plugins/chat/messages/m1/image/raw',
        'content_type': 'image/png',
        'size_bytes': 123,
        'width': 80,
        'height': 60,
      },
    });

    expect(message.isImage, isTrue);
    expect(message.senderAvatarUrl, contains('/avatar?v=2'));
    expect(message.image?.width, 80);
    expect(message.image?.height, 60);
  });

  test('ChatLocalMessage round trips through db map', () {
    final created = DateTime(2026, 6, 25, 18, 30);
    final local = ChatLocalMessage(
      localId: 7,
      serverId: 'm1',
      clientId: 'c1',
      ownerUserId: 'u1',
      familyId: 'f1',
      senderId: 'u1',
      senderName: '爸爸',
      senderEmoji: '👨',
      senderAvatarUrl: '/api/v1/avatar',
      kind: 'text',
      body: '到家了吗',
      status: chatStatusSent,
      createdAt: created,
    );

    final parsed = ChatLocalMessage.fromDb(local.toDb());

    expect(parsed.localId, 7);
    expect(parsed.serverId, 'm1');
    expect(parsed.isMine, isTrue);
    expect(parsed.body, '到家了吗');
    expect(
      parsed.createdAt.toUtc().toIso8601String(),
      created.toUtc().toIso8601String(),
    );
  });
}
