import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/models.dart';

void main() {
  group('accounting JSON parsing (Decimal serialized as string)', () {
    test('AccountingSummary parses string amounts and null budget', () {
      // Shape the remote actually returns: Decimal → JSON string, null budget.
      final s = AccountingSummary.fromJson({
        'month_total': '0',
        'budget': null,
        'remaining': null,
      });
      expect(s.monthTotal, 0);
      expect(s.budget, isNull);
      expect(s.remaining, isNull);
    });

    test('AccountingSummary parses string budget/remaining', () {
      final s = AccountingSummary.fromJson({
        'month_total': '350.50',
        'budget': '1000.00',
        'remaining': '649.50',
      });
      expect(s.monthTotal, 350.5);
      expect(s.budget, 1000.0);
      expect(s.remaining, 649.5);
    });

    test('AccountingSummary tolerates numeric (non-string) amounts', () {
      final s = AccountingSummary.fromJson({'month_total': 12.5});
      expect(s.monthTotal, 12.5);
    });

    test('Expense parses string amount and creator fields', () {
      final e = Expense.fromJson({
        'id': 'x',
        'family_id': 'f',
        'amount': '58.50',
        'category': 'dining',
        'note': '午饭',
        'created_by': 'u',
        'creator_name': '老陈',
        'creator_emoji': '👨',
        'created_at': '2026-05-25T07:00:00Z',
      });
      expect(e.amount, 58.5);
      expect(e.category, 'dining');
      expect(e.creatorName, '老陈');
    });
  });
}
