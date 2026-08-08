import 'dart:convert';

/// Fixed-expense categories the analysis buckets recurring charges into.
///
/// Water, electricity and municipal tax are deliberately one bucket
/// ([BudgetCategory.household]) — they are the same "keeping the house
/// running" cost from a budgeting point of view.
enum BudgetCategory {
  household,
  insurance,
  carAndTransport,
  subscriptions,
  loansAndCommitments,
  communications,
  healthAndEducation,
  other;

  static BudgetCategory parse(String? raw) => BudgetCategory.values.firstWhere(
    (BudgetCategory c) => c.name == raw,
    orElse: () => BudgetCategory.other,
  );
}

/// One salary deposit, attributed to the month it belongs to.
///
/// Only salary counts as income here: the budget is built on regular pay, not
/// on refunds, peer-to-peer transfers or other incidental credits.
///
/// [stream] is the salary keyword that matched the description, so each
/// earner is tracked separately. That matters because a bonus lands inside
/// one person's salary payment — flagging it must not discard the other
/// person's clean salary for that month.
class SalaryEntry {
  const SalaryEntry({
    required this.month,
    required this.stream,
    required this.amount,
    required this.isExtra,
    required this.note,
  });

  final DateTime month;
  final String stream;
  final double amount;

  /// True when this payment is inflated by a bonus or other extra payment,
  /// so it must not set the baseline.
  final bool isExtra;

  /// Why it was flagged, e.g. "yearly bonus". Empty when it is clean pay.
  final String note;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'month': month.toIso8601String(),
    'stream': stream,
    'amount': amount,
    'isExtra': isExtra,
    'note': note,
  };

  static SalaryEntry fromJson(Map<String, dynamic> json) => SalaryEntry(
    month: DateTime.tryParse(json['month'] as String? ?? '') ?? DateTime(2000),
    stream: json['stream'] as String? ?? '',
    amount: (json['amount'] as num?)?.toDouble() ?? 0,
    isExtra: json['isExtra'] as bool? ?? false,
    note: json['note'] as String? ?? '',
  );
}

/// A single recurring charge the analysis identified, e.g. "Car insurance".
class RecurringCharge {
  const RecurringCharge({
    required this.name,
    required this.category,
    required this.monthlyAmount,
    required this.monthsSeen,
    required this.monthsInWindow,
    required this.source,
  });

  final String name;
  final BudgetCategory category;

  /// Mean amount per month over the months it appeared in.
  final double monthlyAmount;

  /// How many distinct months this charge appeared in.
  final int monthsSeen;

  /// The size of the analysis window, so the UI can render "4/6 months".
  final int monthsInWindow;

  /// Where it is billed from — a card name or the bank account name.
  final String source;

  /// A charge seen in more than half the window is a dependable fixed cost;
  /// one seen in half or less is likelier to be a misclassification or a
  /// charge that has since ended, and the UI dims it.
  bool get isConfident => monthsSeen * 2 > monthsInWindow;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'category': category.name,
    'monthlyAmount': monthlyAmount,
    'monthsSeen': monthsSeen,
    'monthsInWindow': monthsInWindow,
    'source': source,
  };

  static RecurringCharge fromJson(Map<String, dynamic> json) => RecurringCharge(
    name: json['name'] as String? ?? '',
    category: BudgetCategory.parse(json['category'] as String?),
    monthlyAmount: (json['monthlyAmount'] as num?)?.toDouble() ?? 0,
    monthsSeen: (json['monthsSeen'] as num?)?.toInt() ?? 0,
    monthsInWindow: (json['monthsInWindow'] as num?)?.toInt() ?? 0,
    source: json['source'] as String? ?? '',
  );
}

/// The stored result of one analysis run. Everything the Budget tab renders
/// comes from here, so the tab paints instantly from disk without waiting on
/// the network or on Gemini.
class BudgetAnalysis {
  const BudgetAnalysis({
    required this.analyzedAt,
    required this.currencyCode,
    required this.windowMonths,
    required this.salary,
    required this.charges,
  });

  final DateTime analyzedAt;
  final String currencyCode;

  /// Number of complete months the window covered.
  final int windowMonths;

  final List<SalaryEntry> salary;
  final List<RecurringCharge> charges;

  Map<String, List<SalaryEntry>> get _byStream {
    final Map<String, List<SalaryEntry>> streams =
        <String, List<SalaryEntry>>{};
    for (final SalaryEntry entry in salary) {
      streams.putIfAbsent(entry.stream, () => <SalaryEntry>[]).add(entry);
    }
    return streams;
  }

  static double _mean(Iterable<double> values) =>
      values.reduce((double a, double b) => a + b) / values.length;

  /// Base monthly income: each earner's normal pay, summed.
  ///
  /// Per stream, months flagged as containing a bonus or extra payment are
  /// dropped and the rest averaged — so one person's bonus month never drags
  /// the other person's salary out of the baseline. If every month of a
  /// stream is flagged there is nothing clean to average, so all of its
  /// months are used rather than dropping that earner entirely.
  double get baseMonthlyIncome {
    double total = 0;
    for (final List<SalaryEntry> entries in _byStream.values) {
      final List<SalaryEntry> clean = entries
          .where((SalaryEntry e) => !e.isExtra)
          .toList();
      final List<SalaryEntry> used = clean.isEmpty ? entries : clean;
      if (used.isEmpty) {
        continue;
      }
      total += _mean(used.map((SalaryEntry e) => e.amount));
    }
    return total;
  }

  /// Household pay per month, oldest first — but only months in which EVERY
  /// earner has a clean payment.
  ///
  /// A month where one earner's pay was set aside as extra would otherwise
  /// look like a household income collapse (their salary simply missing) and
  /// turn the spread into a measure of "months containing a bonus" rather
  /// than of how much regular pay actually varies.
  List<({DateTime month, double amount})> get baseMonths {
    final Set<String> streams = _byStream.keys.toSet();
    final Map<DateTime, Map<String, double>> byMonth =
        <DateTime, Map<String, double>>{};
    for (final SalaryEntry entry in salary.where(
      (SalaryEntry e) => !e.isExtra,
    )) {
      final Map<String, double> month = byMonth.putIfAbsent(
        entry.month,
        () => <String, double>{},
      );
      month[entry.stream] = (month[entry.stream] ?? 0) + entry.amount;
    }

    final List<({DateTime month, double amount})> months = byMonth.entries
        .where(
          (MapEntry<DateTime, Map<String, double>> e) =>
              e.value.keys.toSet().containsAll(streams),
        )
        .map(
          (MapEntry<DateTime, Map<String, double>> e) => (
            month: e.key,
            amount: e.value.values.reduce((double a, double b) => a + b),
          ),
        )
        .toList();
    months.sort(
      (
        ({DateTime month, double amount}) a,
        ({DateTime month, double amount}) b,
      ) => a.month.compareTo(b.month),
    );
    return months;
  }

  /// Mean absolute deviation of clean monthly pay — shown as "±X" so steady
  /// pay reads differently from variable pay.
  double get incomeSpread {
    final List<double> amounts = baseMonths
        .map((({DateTime month, double amount}) m) => m.amount)
        .toList();
    if (amounts.length < 2) {
      return 0;
    }
    final double mean = _mean(amounts);
    return _mean(amounts.map((double v) => (v - mean).abs()));
  }

  /// How many salary payments were set aside as bonus / extra pay.
  int get extraPaymentCount =>
      salary.where((SalaryEntry e) => e.isExtra).length;

  /// The flagged payments, newest first — listed in the income sheet so the
  /// exclusions can be checked rather than taken on trust.
  List<SalaryEntry> get extraPayments {
    final List<SalaryEntry> extras = salary
        .where((SalaryEntry e) => e.isExtra)
        .toList();
    extras.sort(
      (SalaryEntry a, SalaryEntry b) => b.month.compareTo(a.month),
    );
    return extras;
  }

  List<RecurringCharge> chargesIn(BudgetCategory category) => charges
      .where((RecurringCharge c) => c.category == category)
      .toList()
    ..sort(
      (RecurringCharge a, RecurringCharge b) =>
          b.monthlyAmount.compareTo(a.monthlyAmount),
    );

  double totalFor(BudgetCategory category) => chargesIn(category).fold<double>(
    0,
    (double sum, RecurringCharge c) => sum + c.monthlyAmount,
  );

  /// Categories that actually have charges, biggest first.
  List<BudgetCategory> get activeCategories {
    final List<BudgetCategory> active = BudgetCategory.values
        .where((BudgetCategory c) => chargesIn(c).isNotEmpty)
        .toList();
    active.sort(
      (BudgetCategory a, BudgetCategory b) => totalFor(b).compareTo(totalFor(a)),
    );
    return active;
  }

  double get totalFixedExpenses => charges.fold<double>(
    0,
    (double sum, RecurringCharge c) => sum + c.monthlyAmount,
  );

  double get leftToSpend => baseMonthlyIncome - totalFixedExpenses;

  /// Share of income a category consumes, clamped to 0..1 for the bars.
  double shareOf(BudgetCategory category) {
    final double income = baseMonthlyIncome;
    if (income <= 0) {
      return 0;
    }
    return (totalFor(category) / income).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'analyzedAt': analyzedAt.toIso8601String(),
    'currencyCode': currencyCode,
    'windowMonths': windowMonths,
    'salary': salary.map((SalaryEntry e) => e.toJson()).toList(),
    'charges': charges.map((RecurringCharge c) => c.toJson()).toList(),
  };

  String encode() => jsonEncode(toJson());

  /// Decodes a stored analysis, or null if it is missing, corrupt, or was
  /// written by an older version whose shape no longer applies. An analysis
  /// with no salary can never be produced by a successful run, so it is the
  /// marker for "re-run rather than render zeroes".
  static BudgetAnalysis? decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;
      if ((json['salary'] as List<dynamic>? ?? <dynamic>[]).isEmpty) {
        return null;
      }
      return BudgetAnalysis(
        analyzedAt:
            DateTime.tryParse(json['analyzedAt'] as String? ?? '') ??
            DateTime(2000),
        currencyCode: json['currencyCode'] as String? ?? '',
        windowMonths: (json['windowMonths'] as num?)?.toInt() ?? 6,
        salary: (json['salary'] as List<dynamic>? ?? <dynamic>[])
            .map((dynamic e) => SalaryEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        charges: (json['charges'] as List<dynamic>? ?? <dynamic>[])
            .map(
              (dynamic e) => RecurringCharge.fromJson(e as Map<String, dynamic>),
            )
            .toList(),
      );
    } on FormatException {
      return null;
    }
  }
}
