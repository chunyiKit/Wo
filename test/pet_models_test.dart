import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/models.dart';

void main() {
  test('Family separates human and pet counts and rejects legacy role shape',
      () {
    final family = Family.fromJson({
      'id': 'f1',
      'name': '我的家',
      'emoji': '🏡',
      'member_count': 3,
      'pet_count': 2,
      'my_role': 'admin',
    });
    expect(family.memberCount, 3);
    expect(family.petCount, 2);
    expect(family.myRole, 'admin');
  });

  test('Pet image falls back independently and dashboard parses all sections',
      () {
    final dashboard = PetDashboard.fromJson({
      'pet': {
        'id': 'p1',
        'family_id': 'f1',
        'name': '团子',
        'emoji': '🐈',
        'photo_url': null,
      },
      'today_plans': [
        {
          'id': 'plan1',
          'pet_id': 'p1',
          'record_type_id': 't1',
          'type_name': '驱虫',
          'type_emoji': '🛡️',
          'data_kind': 'general',
          'name': '体内驱虫',
          'recurrence_unit': 'month',
          'recurrence_interval': 3,
          'next_due_date': '2026-08-14',
          'active': true,
        },
      ],
      'upcoming_plans': [],
      'latest_weight': {
        'record_id': 'r1',
        'occurred_on': '2026-08-13',
        'weight_kg': '4.850',
      },
      'weight_trend': [],
      'records': [
        {
          'id': 'r1',
          'pet_id': 'p1',
          'record_type_id': 't2',
          'type_name': '体重',
          'type_emoji': '⚖️',
          'data_kind': 'weight',
          'name': '晨间体重',
          'occurred_on': '2026-08-13',
          'weight_kg': '4.850',
          'creator_name': '老陈',
          'creator_emoji': '👨',
          'creator_avatar_url': '/avatar?v=1',
          'attachments': [],
        },
      ],
      'records_cursor': 'next',
    });

    expect(dashboard.pet.hasPhoto, isFalse);
    expect(dashboard.pet.emoji, '🐈');
    expect(dashboard.todayPlans.single.recurrenceInterval, 3);
    expect(dashboard.latestWeight!.weightKg, 4.85);
    expect(dashboard.records.single.creatorAvatarUrl, '/avatar?v=1');
    expect(dashboard.recordsCursor, 'next');
  });

  test('Record types preserve stable data kind', () {
    final type = PetRecordType.fromJson({
      'id': 't1',
      'name': '体重',
      'emoji': '⚖️',
      'data_kind': 'weight',
      'sort_order': 7,
      'archived': false,
    });
    expect(type.isWeight, isTrue);
    expect(type.sortOrder, 7);
  });
}
