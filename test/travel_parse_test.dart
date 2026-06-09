import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/models.dart';

void main() {
  group('TravelTrip / TravelCity parsing', () {
    test('TravelTrip parses cover/ai fields', () {
      final t = TravelTrip.fromJson({
        'id': 't1',
        'city_name': '三亚',
        'city_lng': 109.51,
        'city_lat': 18.25,
        'caption': '蜜月最后一晚',
        'chosen': 'ai',
        'has_ai': true,
        'ai_prompt': '吉卜力黄昏',
        'ai_style': '吉卜力',
        'original_url': '/api/v1/families/f/plugins/travel/trips/t1/image/original',
        'ai_url': '/api/v1/families/f/plugins/travel/trips/t1/image/ai',
        'cover_url': '/api/v1/families/f/plugins/travel/trips/t1/image/ai',
        'created_at': '2026-06-08T10:00:00Z',
      });
      expect(t.cityName, '三亚');
      expect(t.cityLng, closeTo(109.51, 1e-6));
      expect(t.chosen, 'ai');
      expect(t.hasAi, isTrue);
      expect(t.aiStyle, '吉卜力');
      expect(t.coverUrl.endsWith('/image/ai'), isTrue);
      expect(t.aiUrl, isNotNull);
    });

    test('TravelTrip without AI defaults to original cover', () {
      final t = TravelTrip.fromJson({
        'id': 't2',
        'city_name': '北京',
        'city_lng': 116.4,
        'city_lat': 39.9,
        'chosen': 'original',
        'has_ai': false,
        'original_url': '/x/original',
        'cover_url': '/x/original',
      });
      expect(t.hasAi, isFalse);
      expect(t.aiUrl, isNull);
      expect(t.chosen, 'original');
    });

    test('TravelCity parses name + coords', () {
      final c = TravelCity.fromJson({'name': '杭州', 'lng': 120.15, 'lat': 30.27});
      expect(c.name, '杭州');
      expect(c.lng, closeTo(120.15, 1e-6));
      expect(c.lat, closeTo(30.27, 1e-6));
    });
  });
}
