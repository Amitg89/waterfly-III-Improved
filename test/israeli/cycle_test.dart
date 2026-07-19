import 'package:flutter_test/flutter_test.dart';
import 'package:waterflyiii/israeli/accounts_service.dart';

void main() {
  group('currentCycle', () {
    test('day before cycle day: charge date is cycle day of this month', () {
      final ({DateTime start, DateTime end}) cycle = currentCycle(
        DateTime(2026, 7, 9),
        10,
      );
      expect(cycle.start, DateTime(2026, 6, 10));
      expect(cycle.end, DateTime(2026, 7, 10));
    });

    test('on cycle day: charge already happened, next is next month', () {
      final ({DateTime start, DateTime end}) cycle = currentCycle(
        DateTime(2026, 7, 10),
        10,
      );
      expect(cycle.start, DateTime(2026, 7, 10));
      expect(cycle.end, DateTime(2026, 8, 10));
    });

    test('day after cycle day: charge date is cycle day of next month', () {
      final ({DateTime start, DateTime end}) cycle = currentCycle(
        DateTime(2026, 7, 11),
        10,
      );
      expect(cycle.start, DateTime(2026, 7, 10));
      expect(cycle.end, DateTime(2026, 8, 10));
    });

    test('December to January rollover (after cycle day)', () {
      final ({DateTime start, DateTime end}) cycle = currentCycle(
        DateTime(2025, 12, 15),
        10,
      );
      expect(cycle.start, DateTime(2025, 12, 10));
      expect(cycle.end, DateTime(2026, 1, 10));
    });

    test('January before cycle day: previous charge was in December', () {
      final ({DateTime start, DateTime end}) cycle = currentCycle(
        DateTime(2026, 1, 5),
        10,
      );
      expect(cycle.start, DateTime(2025, 12, 10));
      expect(cycle.end, DateTime(2026, 1, 10));
    });

    test('time of day is ignored, non-default cycle day works', () {
      final ({DateTime start, DateTime end}) cycle = currentCycle(
        DateTime(2026, 3, 1, 23, 59, 59),
        2,
      );
      expect(cycle.start, DateTime(2026, 2, 2));
      expect(cycle.end, DateTime(2026, 3, 2));
    });
  });
}
