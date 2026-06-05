import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/models.dart';

void main() {
  group('ExpiryItem JSON parsing', () {
    test('parses fields incl. date-only expire_on and days_until', () {
      final e = ExpiryItem.fromJson({
        'id': 'x',
        'family_id': 'f',
        'name': '老爸的护照',
        'emoji': '📘',
        'kind': 'passport',
        'expire_on': '2027-01-15',
        'note': '到期前去出入境办',
        'notify_enabled': true,
        'notify_days_before': 60,
        'active': true,
        'days_until': 225,
      });
      expect(e.name, '老爸的护照');
      expect(e.kind, 'passport');
      expect(e.expireOn, DateTime(2027, 1, 15));
      expect(e.notifyDaysBefore, 60);
      expect(e.daysUntil, 225);
    });

    test('missing optional fields fall back to defaults', () {
      final e = ExpiryItem.fromJson({
        'id': 'x',
        'family_id': 'f',
        'name': '车险',
        'expire_on': '2026-09-01',
      });
      expect(e.emoji, '📄');
      expect(e.kind, 'other');
      expect(e.notifyEnabled, isTrue);
      expect(e.notifyDaysBefore, 30);
      expect(e.active, isTrue);
      expect(e.daysUntil, 0);
    });
  });

  group('ReceiptDraft JSON parsing', () {
    test('parses string amount + fields', () {
      final d = ReceiptDraft.fromJson({
        'amount': '88.00',
        'category': 'shopping',
        'merchant': '山姆',
        'note': '周末采买',
      });
      expect(d.amount, 88.0);
      expect(d.category, 'shopping');
      expect(d.merchant, '山姆');
      expect(d.note, '周末采买');
    });

    test('null amount stays null; category defaults to shopping', () {
      final d = ReceiptDraft.fromJson({'amount': null, 'merchant': '某店'});
      expect(d.amount, isNull);
      expect(d.category, 'shopping');
      expect(d.merchant, '某店');
    });
  });
}
