import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/israeli/budget/models.dart';
import 'package:waterflyiii/pages/home/budget/labels.dart';
import 'package:waterflyiii/pages/home/budget/recalculate.dart';

/// Bottom sheet listing every recurring charge in one category, with the
/// per-category recalculate box underneath.
class CategorySheet extends StatelessWidget {
  const CategorySheet({
    super.key,
    required this.analysis,
    required this.category,
    required this.currencyFormat,
    required this.rules,
    required this.onRecalculate,
  });

  final BudgetAnalysis analysis;
  final BudgetCategory category;
  final NumberFormat currencyFormat;
  final List<String> rules;

  /// Called with the user's correction; the caller stores it as a rule and
  /// re-runs the analysis.
  final Future<void> Function(String rule) onRecalculate;

  static Future<void> show({
    required BuildContext context,
    required BudgetAnalysis analysis,
    required BudgetCategory category,
    required NumberFormat currencyFormat,
    required List<String> rules,
    required Future<void> Function(String rule) onRecalculate,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => CategorySheet(
      analysis: analysis,
      category: category,
      currencyFormat: currencyFormat,
      rules: rules,
      onRecalculate: onRecalculate,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final ThemeData theme = Theme.of(context);
    final List<RecurringCharge> charges = analysis.chargesIn(category);
    final double share = analysis.shareOf(category) * 100;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Expanded(
                  child: Text(
                    categoryLabel(l10n, category),
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                Text(
                  currencyFormat.format(analysis.totalFor(category)),
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              l10n.budgetCategorySubtitle(
                charges.length,
                share.toStringAsFixed(0),
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ...charges.map(
              (RecurringCharge charge) => _ChargeRow(
                charge: charge,
                currencyFormat: currencyFormat,
              ),
            ),
            const SizedBox(height: 20),
            RecalculateBox(
              hintText: l10n.budgetRecalculateCategoryHint,
              rules: rules,
              onSubmit: onRecalculate,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChargeRow extends StatelessWidget {
  const _ChargeRow({required this.charge, required this.currencyFormat});

  final RecurringCharge charge;
  final NumberFormat currencyFormat;

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final ThemeData theme = Theme.of(context);
    final String seen = l10n.budgetChargeSeen(
      charge.monthsSeen,
      charge.monthsInWindow,
    );

    return Opacity(
      // A charge that only shows up in half the window is more likely a
      // mislabel or something that has ended, so it is visibly demoted
      // rather than silently mixed in with the dependable ones.
      opacity: charge.isConfident ? 1 : 0.62,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(charge.name, style: theme.textTheme.bodyMedium),
                  Text(
                    charge.source.isEmpty ? seen : '${charge.source} · $seen',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: charge.isConfident
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              currencyFormat.format(charge.monthlyAmount),
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
