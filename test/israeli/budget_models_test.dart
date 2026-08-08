import 'package:flutter_test/flutter_test.dart';
import 'package:waterflyiii/israeli/budget/analyzer.dart';
import 'package:waterflyiii/israeli/budget/models.dart';

const String _me = 'מזרחי טפחו משכורת';
const String _spouse = 'שיכון ובינ משכורת';

BudgetAnalysis _analysis({
  List<SalaryEntry> salary = const <SalaryEntry>[],
  List<RecurringCharge> charges = const <RecurringCharge>[],
}) => BudgetAnalysis(
  analyzedAt: DateTime(2026, 8, 8),
  currencyCode: 'ILS',
  windowMonths: 6,
  salary: salary,
  charges: charges,
);

SalaryEntry _pay(
  int month,
  String stream,
  double amount, {
  bool extra = false,
}) => SalaryEntry(
  month: DateTime(2026, month, 1),
  stream: stream,
  amount: amount,
  isExtra: extra,
  note: extra ? 'bonus' : '',
);

RecurringCharge _charge(
  String name,
  BudgetCategory category,
  double amount, {
  int seen = 6,
}) => RecurringCharge(
  name: name,
  category: category,
  monthlyAmount: amount,
  monthsSeen: seen,
  monthsInWindow: 6,
  source: 'Max',
);

void main() {
  group('analysis window', () {
    test('covers the 6 complete months before the current one', () {
      final ({DateTime start, DateTime endExclusive}) w = budgetWindow(
        DateTime(2026, 8, 8),
      );
      expect(w.start, DateTime(2026, 2, 1));
      // August itself is excluded: on the 8th it is only a partial month.
      expect(w.endExclusive, DateTime(2026, 8, 1));
    });

    test('rolls across a year boundary', () {
      final ({DateTime start, DateTime endExclusive}) w = budgetWindow(
        DateTime(2026, 1, 20),
      );
      expect(w.start, DateTime(2025, 7, 1));
      expect(w.endExclusive, DateTime(2026, 1, 1));
    });
  });

  group('early salary attribution', () {
    test('pay on the 30th or 31st belongs to the next month', () {
      expect(salaryMonthFor(DateTime(2026, 3, 31)), DateTime(2026, 4, 1));
      expect(salaryMonthFor(DateTime(2026, 3, 30)), DateTime(2026, 4, 1));
    });

    test('pay early in the month belongs to that month', () {
      expect(salaryMonthFor(DateTime(2026, 4, 1)), DateTime(2026, 4, 1));
      expect(salaryMonthFor(DateTime(2026, 4, 10)), DateTime(2026, 4, 1));
    });

    test('December rolls into January of the next year', () {
      expect(salaryMonthFor(DateTime(2026, 12, 31)), DateTime(2027, 1, 1));
    });
  });

  group('salary matching', () {
    test('matches a configured keyword and reports which one', () {
      expect(
        matchSalaryStream('מזרחי טפחו משכורת 08/26', <String>[_me, _spouse]),
        _me,
      );
    });

    test('ignores non-salary deposits', () {
      // The kind of noise that used to inflate the old all-deposits income.
      expect(
        matchSalaryStream('החזר עמלה', <String>[_me, _spouse]),
        isNull,
      );
      expect(matchSalaryStream('Bit transfer', <String>[_me]), isNull);
    });
  });

  group('base income', () {
    test('is the sum of both earners normal pay', () {
      final BudgetAnalysis a = _analysis(
        salary: <SalaryEntry>[
          _pay(4, _me, 20000),
          _pay(5, _me, 20000),
          _pay(4, _spouse, 12000),
          _pay(5, _spouse, 12000),
        ],
      );
      expect(a.baseMonthlyIncome, 32000);
    });

    test('one earner bonus month does not discard the other earner', () {
      // March: my pay carries a bonus; my wife's March pay is normal and must
      // still count towards her baseline.
      final BudgetAnalysis a = _analysis(
        salary: <SalaryEntry>[
          _pay(3, _me, 48000, extra: true),
          _pay(4, _me, 20000),
          _pay(5, _me, 20000),
          _pay(3, _spouse, 12000),
          _pay(4, _spouse, 12000),
          _pay(5, _spouse, 12000),
        ],
      );
      expect(a.baseMonthlyIncome, 32000);
      expect(a.extraPaymentCount, 1);
    });

    test('each earner is averaged over their own clean months only', () {
      final BudgetAnalysis a = _analysis(
        salary: <SalaryEntry>[
          _pay(4, _me, 19000),
          _pay(5, _me, 21000),
          _pay(6, _me, 90000, extra: true),
        ],
      );
      expect(a.baseMonthlyIncome, 20000);
    });

    test('falls back to all months when every month is flagged', () {
      // Better a rough baseline than dropping the earner entirely.
      final BudgetAnalysis a = _analysis(
        salary: <SalaryEntry>[
          _pay(4, _me, 20000, extra: true),
          _pay(5, _me, 22000, extra: true),
        ],
      );
      expect(a.baseMonthlyIncome, 21000);
    });

    test('spread ignores flagged months', () {
      final BudgetAnalysis a = _analysis(
        salary: <SalaryEntry>[
          _pay(4, _me, 19000),
          _pay(5, _me, 21000),
          _pay(6, _me, 90000, extra: true),
        ],
      );
      expect(a.baseMonths.length, 2);
      expect(a.incomeSpread, 1000);
    });

    test('a month missing one earner is not counted as an income drop', () {
      // March holds only my wife's pay because mine was set aside as a bonus.
      // Counting it would read as the household earning 12k that month and
      // make the spread measure bonuses rather than pay variability.
      final BudgetAnalysis a = _analysis(
        salary: <SalaryEntry>[
          _pay(3, _me, 48000, extra: true),
          _pay(4, _me, 20000),
          _pay(5, _me, 20000),
          _pay(3, _spouse, 12000),
          _pay(4, _spouse, 12000),
          _pay(5, _spouse, 12000),
        ],
      );
      expect(a.baseMonths.map((({DateTime month, double amount}) m) =>
          m.month.month), <int>[4, 5]);
      expect(a.incomeSpread, 0);
    });

    test('steady pay has no spread', () {
      final BudgetAnalysis a = _analysis(
        salary: <SalaryEntry>[_pay(4, _me, 20000), _pay(5, _me, 20000)],
      );
      expect(a.incomeSpread, 0);
    });

    test('extra payments are listed newest first for checking', () {
      final BudgetAnalysis a = _analysis(
        salary: <SalaryEntry>[
          _pay(3, _me, 48000, extra: true),
          _pay(6, _spouse, 30000, extra: true),
          _pay(4, _me, 20000),
        ],
      );
      expect(a.extraPayments.map((SalaryEntry e) => e.month.month), <int>[
        6,
        3,
      ]);
    });
  });

  group('categories', () {
    final BudgetAnalysis a = _analysis(
      salary: <SalaryEntry>[_pay(4, _me, 10000), _pay(5, _me, 10000)],
      charges: <RecurringCharge>[
        _charge('Car insurance', BudgetCategory.insurance, 600),
        _charge('Home insurance', BudgetCategory.insurance, 400),
        _charge('Electricity', BudgetCategory.household, 500),
      ],
    );

    test('sums charges per category', () {
      expect(a.totalFor(BudgetCategory.insurance), 1000);
      expect(a.totalFor(BudgetCategory.household), 500);
    });

    test('share of income drives the progress bars', () {
      expect(a.shareOf(BudgetCategory.insurance), 0.1);
    });

    test('active categories are ordered biggest first', () {
      expect(a.activeCategories, <BudgetCategory>[
        BudgetCategory.insurance,
        BudgetCategory.household,
      ]);
    });

    test('left to spend is income minus all fixed charges', () {
      expect(a.totalFixedExpenses, 1500);
      expect(a.leftToSpend, 8500);
    });

    test('shares stay clamped when charges exceed income', () {
      final BudgetAnalysis over = _analysis(
        salary: <SalaryEntry>[_pay(4, _me, 1000)],
        charges: <RecurringCharge>[
          _charge('Rent', BudgetCategory.loansAndCommitments, 5000),
        ],
      );
      expect(over.shareOf(BudgetCategory.loansAndCommitments), 1.0);
      expect(over.leftToSpend, -4000);
    });

    test('no salary does not divide by zero', () {
      final BudgetAnalysis empty = _analysis(
        charges: <RecurringCharge>[
          _charge('Gym', BudgetCategory.subscriptions, 100),
        ],
      );
      expect(empty.baseMonthlyIncome, 0);
      expect(empty.shareOf(BudgetCategory.subscriptions), 0);
    });
  });

  group('confidence', () {
    test('a charge seen more than half the window is confident', () {
      expect(
        _charge('Water', BudgetCategory.household, 200, seen: 6).isConfident,
        isTrue,
      );
      expect(
        _charge('Water', BudgetCategory.household, 200, seen: 4).isConfident,
        isTrue,
      );
    });

    test('a charge seen half the window or less is not', () {
      expect(
        _charge('Pet', BudgetCategory.insurance, 45, seen: 3).isConfident,
        isFalse,
      );
    });
  });

  test('survives a round trip through storage', () {
    final BudgetAnalysis a = _analysis(
      salary: <SalaryEntry>[
        _pay(3, _me, 48000, extra: true),
        _pay(4, _me, 20000),
      ],
      charges: <RecurringCharge>[
        _charge('Car insurance', BudgetCategory.insurance, 600),
      ],
    );
    final BudgetAnalysis? back = BudgetAnalysis.decode(a.encode());
    expect(back, isNotNull);
    expect(back!.baseMonthlyIncome, a.baseMonthlyIncome);
    expect(back.windowMonths, 6);
    expect(back.charges.single.name, 'Car insurance');
    expect(back.extraPayments.single.stream, _me);
    expect(back.extraPayments.single.note, 'bonus');
  });

  test('decoding junk returns null instead of throwing', () {
    expect(BudgetAnalysis.decode(null), isNull);
    expect(BudgetAnalysis.decode(''), isNull);
    expect(BudgetAnalysis.decode('not json'), isNull);
  });

  test('a record from the older schema is discarded, not rendered as zero', () {
    // Pre-salary-model shape: it would otherwise decode to 0 income.
    const String old =
        '{"analyzedAt":"2026-08-08T00:00:00.000","currencyCode":"ILS",'
        '"incomeMonths":[{"month":"2026-04-01T00:00:00.000","total":20000,'
        '"oneOff":0,"note":""}],"charges":[]}';
    expect(BudgetAnalysis.decode(old), isNull);
  });

  test('an unknown category from the model falls back to other', () {
    expect(BudgetCategory.parse('nonsense'), BudgetCategory.other);
    expect(BudgetCategory.parse(null), BudgetCategory.other);
    expect(BudgetCategory.parse('household'), BudgetCategory.household);
  });
}
