import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';
import 'package:waterflyiii/israeli/budget/analyzer.dart';
import 'package:waterflyiii/israeli/budget/models.dart';
import 'package:waterflyiii/israeli/budget/store.dart';
import 'package:waterflyiii/pages/home/budget/category_sheet.dart';
import 'package:waterflyiii/pages/home/budget/labels.dart';
import 'package:waterflyiii/pages/home/budget/recalculate.dart';
import 'package:waterflyiii/settings.dart';
import 'package:waterflyiii/theme.dart';

final Logger _log = Logger("Pages.Home.Budget");

typedef _Slice = ({String label, double value, Color color});

class HomeBudget extends StatefulWidget {
  const HomeBudget({super.key});

  @override
  State<HomeBudget> createState() => _HomeBudgetState();
}

class _HomeBudgetState extends State<HomeBudget>
    with AutomaticKeepAliveClientMixin {
  final BudgetAnalysisStore _store = BudgetAnalysisStore();

  BudgetAnalysis? _analysis;
  List<String> _rules = <String>[];
  bool _loading = true;
  bool _running = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  /// Paints from disk first, then re-runs only if the stored analysis has
  /// aged out. The tab is never gated behind a network call.
  Future<void> _restore() async {
    final BudgetAnalysis? stored = await _store.readAnalysis();
    final List<String> rules = await _store.readRules();
    if (!mounted) {
      return;
    }
    setState(() {
      _analysis = stored;
      _rules = rules;
      _loading = false;
    });
    if (BudgetAnalysisStore.isStale(stored, DateTime.now())) {
      await _run();
    }
  }

  Future<void> _run({String? newRule}) async {
    if (_running) {
      return;
    }
    final S l10n = S.of(context);
    final FireflyService firefly = context.read<FireflyService>();
    final String? key = await firefly.getGeminiApiKey();
    if (key == null || key.isEmpty) {
      if (mounted) {
        setState(() => _error = l10n.analyzeAddGeminiKeyInSettings);
      }
      return;
    }

    List<String> rules = _rules;
    if (newRule != null && newRule.trim().isNotEmpty) {
      rules = await _store.addRule(newRule);
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _rules = rules;
    });

    try {
      final FireflyIii api = firefly.api;
      final BudgetAnalysis analysis = await runBudgetAnalysis(
        api: api,
        geminiApiKey: key,
        salaryKeywords: context.read<SettingsProvider>().salaryKeywordsList,
        rules: rules,
      );
      await _store.writeAnalysis(analysis);
      if (mounted) {
        setState(() {
          _analysis = analysis;
          _running = false;
        });
      }
    } catch (e, stackTrace) {
      _log.severe("budget analysis failed", e, stackTrace);
      if (mounted) {
        setState(() {
          _running = false;
          _error = e is BudgetAnalysisException
              ? e.message
              : S.of(context).budgetErrorGeneric;
        });
      }
    }
  }

  NumberFormat _currencyFormat(BudgetAnalysis analysis) =>
      NumberFormat.simpleCurrency(
        locale: Intl.defaultLocale,
        name: analysis.currencyCode.isEmpty ? null : analysis.currencyCode,
        decimalDigits: 0,
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final S l10n = S.of(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final BudgetAnalysis? analysis = _analysis;
    if (analysis == null) {
      return _EmptyState(
        running: _running,
        error: _error,
        onRun: () => _run(),
      );
    }

    final NumberFormat currency = _currencyFormat(analysis);

    return RefreshIndicator(
      onRefresh: () => _run(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 84),
        children: <Widget>[
          if (_error != null) ...<Widget>[
            _ErrorBanner(message: _error!),
            const SizedBox(height: 8),
          ],
          _IncomeHeader(
            analysis: analysis,
            currency: currency,
            running: _running,
            onRecalculate: _openIncomeRecalculate,
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              l10n.budgetFixedExpensesTitle,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (analysis.activeCategories.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.budgetNoFixedExpenses,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )
          else
            ...analysis.activeCategories.map(
              (BudgetCategory category) => _CategoryBar(
                analysis: analysis,
                category: category,
                currency: currency,
                onTap: () => _openCategory(analysis, category, currency),
              ),
            ),
          const SizedBox(height: 8),
          _BudgetDonut(analysis: analysis, currency: currency),
        ],
      ),
    );
  }

  Future<void> _openCategory(
    BudgetAnalysis analysis,
    BudgetCategory category,
    NumberFormat currency,
  ) => CategorySheet.show(
    context: context,
    analysis: analysis,
    category: category,
    currencyFormat: currency,
    rules: _rules,
    onRecalculate: (String rule) async {
      Navigator.of(context).pop();
      await _run(newRule: rule);
    },
  );

  Future<void> _openIncomeRecalculate() async {
    final BudgetAnalysis? analysis = _analysis;
    if (analysis == null) {
      return;
    }
    final NumberFormat currency = _currencyFormat(analysis);
    final S l10n = S.of(context);
    final DateFormat monthFmt = DateFormat.yMMMM(Intl.defaultLocale);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final ThemeData theme = Theme.of(sheetContext);
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  l10n.budgetIncomeLabel,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.budgetIncomeSheetSubtitle(analysis.windowMonths),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.budgetExcludedTitle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (analysis.extraPayments.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      l10n.budgetExcludedNone,
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                else
                  ...analysis.extraPayments.map(
                    (SalaryEntry entry) => Container(
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(color: theme.dividerColor),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  '${monthFmt.format(entry.month)} · '
                                  '${entry.stream}',
                                  style: theme.textTheme.bodyMedium,
                                ),
                                if (entry.note.isNotEmpty)
                                  Text(
                                    entry.note,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            currency.format(entry.amount),
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                RecalculateBox(
                  hintText: l10n.budgetRecalculateIncomeHint,
                  rules: _rules,
                  onSubmit: (String rule) async {
                    Navigator.of(sheetContext).pop();
                    await _run(newRule: rule);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _IncomeHeader extends StatelessWidget {
  const _IncomeHeader({
    required this.analysis,
    required this.currency,
    required this.running,
    required this.onRecalculate,
  });

  final BudgetAnalysis analysis;
  final NumberFormat currency;
  final bool running;
  final VoidCallback onRecalculate;

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final ThemeData theme = Theme.of(context);
    final MoneyColors mc = theme.extension<MoneyColors>()!;
    final Color foreground = mc.heroForeground;
    final double spent = analysis.totalFixedExpenses;
    final double income = analysis.baseMonthlyIncome;
    final double fraction = income <= 0
        ? 0.0
        : (spent / income).clamp(0.0, 1.0);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: mc.heroGradient),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  l10n.budgetIncomeLabel.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              IconButton(
                onPressed: running ? null : onRecalculate,
                tooltip: l10n.budgetRecalculate,
                icon: running
                    ? SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: foreground,
                        ),
                      )
                    : Icon(Icons.refresh, color: foreground),
              ),
            ],
          ),
          Text(
            currency.format(income),
            style: theme.textTheme.headlineMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: foreground.withValues(alpha: 0.25),
              valueColor: AlwaysStoppedAnimation<Color>(foreground),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.budgetIncomeSubtitle(
              analysis.windowMonths,
              analysis.extraPaymentCount,
              currency.format(analysis.incomeSpread),
            ),
            style: theme.textTheme.bodySmall?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({
    required this.analysis,
    required this.category,
    required this.currency,
    required this.onTap,
  });

  final BudgetAnalysis analysis;
  final BudgetCategory category;
  final NumberFormat currency;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final ThemeData theme = Theme.of(context);
    final double share = analysis.shareOf(category);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      categoryIcon(category),
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        categoryLabel(l10n, category),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      '${currency.format(analysis.totalFor(category))} · '
                      '${(share * 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: share,
                    minHeight: 6,
                    backgroundColor: theme.colorScheme.surfaceContainerLow,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      theme.colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Income as the whole ring; each fixed-expense category eats a slice and the
/// remainder is the gold slice, with the amount left in the middle.
class _BudgetDonut extends StatelessWidget {
  const _BudgetDonut({required this.analysis, required this.currency});

  final BudgetAnalysis analysis;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final ThemeData theme = Theme.of(context);
    final MoneyColors mc = theme.extension<MoneyColors>()!;
    final double income = analysis.baseMonthlyIncome;
    final double left = analysis.leftToSpend;

    if (income <= 0) {
      return const SizedBox.shrink();
    }

    final List<BudgetCategory> categories = analysis.activeCategories;
    final List<_Slice> slices = <_Slice>[
      if (left > 0)
        (
          label: l10n.budgetLeftToSpend,
          value: left,
          color: mc.goldDeep,
        ),
      ...categories.indexed.map(
        ((int, BudgetCategory) entry) => (
          label: categoryLabel(l10n, entry.$2),
          value: analysis.totalFor(entry.$2),
          color: categorySliceColors[entry.$1 % categorySliceColors.length],
        ),
      ),
    ];

    final double percentLeft = (left / income * 100).clamp(0, 100);

    return SizedBox(
      height: 320,
      // The centre label is a chart annotation rather than a Stack child:
      // the legend steals height from the bottom, so the ring's centre is not
      // the box's centre and a hand-tuned offset collides with the ring.
      child: SfCircularChart(
        margin: EdgeInsets.zero,
        legend: const Legend(
          isVisible: true,
          position: LegendPosition.bottom,
          overflowMode: LegendItemOverflowMode.wrap,
        ),
        annotations: <CircularChartAnnotation>[
          CircularChartAnnotation(
            widget: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  l10n.budgetLeftToSpend.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  currency.format(left),
                  style: theme.textTheme.titleLarge,
                ),
                Text(
                  l10n.budgetPercentOfIncome(percentLeft.toStringAsFixed(0)),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
        series: <CircularSeries<_Slice, String>>[
          DoughnutSeries<_Slice, String>(
            dataSource: slices,
            xValueMapper: (_Slice s, _) => s.label,
            yValueMapper: (_Slice s, _) => s.value,
            pointColorMapper: (_Slice s, _) => s.color,
            innerRadius: '70%',
            radius: '78%',
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.running,
    required this.error,
    required this.onRun,
  });

  final bool running;
  final String? error;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final ThemeData theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.auto_awesome,
              size: 40,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.budgetEmptyTitle,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              l10n.budgetEmptyBody(budgetWindowMonths),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: running ? null : onRun,
              icon: running
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(l10n.budgetAnalyzeNow),
            ),
          ],
        ),
      ),
    );
  }
}
