import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/models.dart';

void main() {
  group('Memory JSON parsing', () {
    test('Memory parses nested media + comments + author', () {
      final m = Memory.fromJson({
        'id': 'm1',
        'family_id': 'f1',
        'title': '搬家纪念',
        'body': '新家第一晚。',
        'mood': '🥹',
        'location': '新家',
        'visibility': 'family',
        'event_date': '2026-05-25',
        'author_name': '小柚',
        'author_emoji': '🌼',
        'media': [
          {
            'id': 'media1',
            'memory_id': 'm1',
            'kind': 'photo',
            'url': '/api/v1/x/raw',
            'content_type': 'image/jpeg',
            'size_bytes': 1234,
            'width': 100,
            'height': 80,
            'sort_order': 0,
          },
        ],
        'comment_count': 1,
        'comments': [
          {
            'id': 'c1',
            'body': '明天再去',
            'author_id': 'u2',
            'author_name': '阿哲',
            'author_emoji': '🌊',
          },
        ],
      });
      expect(m.title, '搬家纪念');
      expect(m.eventDate.year, 2026);
      expect(m.eventDate.month, 5);
      expect(m.media, hasLength(1));
      expect(m.media.first.isVideo, isFalse);
      expect(m.commentCount, 1);
      expect(m.comments.first.authorName, '阿哲');
    });

    test('video media exposes formatted duration label', () {
      final media = MemoryMedia.fromJson({
        'id': 'v1',
        'memory_id': 'm1',
        'kind': 'video',
        'url': '/raw',
        'content_type': 'video/mp4',
        'size_bytes': 999,
        'duration_ms': 14000,
        'sort_order': 1,
      });
      expect(media.isVideo, isTrue);
      expect(media.durationLabel, '0:14');
    });

    test('missing optional fields fall back gracefully', () {
      final m = Memory.fromJson({'id': 'm2', 'title': '只有标题'});
      expect(m.body, isNull);
      expect(m.media, isEmpty);
      expect(m.comments, isEmpty);
      expect(m.visibility, 'family');
    });
  });
}
