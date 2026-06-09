import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/models.dart';

void main() {
  group('TravelTrip / TravelCity parsing', () {
    test('TravelTrip parses fields + linked memory', () {
      final t = TravelTrip.fromJson({
        'id': 't1',
        'city_name': '三亚',
        'city_lng': 109.51,
        'city_lat': 18.25,
        'place': '亚龙湾',
        'caption': '蜜月最后一晚',
        'image_url': '/api/v1/families/f/plugins/travel/trips/t1/image?v=1',
        'ai_status': 'ready',
        'created_at': '2026-06-08T10:00:00Z',
        'memory_id': 'm1',
        'memory': {
          'id': 'm1',
          'title': '海边的傍晚',
          'event_date': '2026-06-08',
          'cover_url': '/api/v1/families/f/plugins/memory/memories/m1/media/x/raw',
        },
      });
      expect(t.cityName, '三亚');
      expect(t.cityLng, closeTo(109.51, 1e-6));
      expect(t.place, '亚龙湾');
      expect(t.aiStatus, 'ready');
      expect(t.isGenerating, isFalse);
      expect(t.memoryId, 'm1');
      expect(t.memory, isNotNull);
      expect(t.memory!.title, '海边的傍晚');
      expect(t.memory!.eventDate, isNotNull);
      expect(t.memory!.eventDate!.year, 2026);
      expect(t.memory!.eventDate!.month, 6);
      expect(t.memory!.eventDate!.day, 8);
      expect(t.memory!.coverUrl!.endsWith('/raw'), isTrue);
    });

    test('TravelTrip without a link parses memory as null', () {
      final t = TravelTrip.fromJson({
        'id': 't2',
        'city_name': '北京',
        'city_lng': 116.4,
        'city_lat': 39.9,
        'image_url': '/x/image?v=2',
        'ai_status': 'generating',
      });
      expect(t.isGenerating, isTrue);
      expect(t.memoryId, isNull);
      expect(t.memory, isNull);
    });

    test('TravelCity parses name + coords + region', () {
      final c = TravelCity.fromJson({
        'name': '余杭区',
        'lng': 119.98,
        'lat': 30.27,
        'region': '杭州市',
      });
      expect(c.name, '余杭区');
      expect(c.lng, closeTo(119.98, 1e-6));
      expect(c.region, '杭州市');
    });
  });
}
