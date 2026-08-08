import 'package:flutter/material.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/israeli/budget/models.dart';

String categoryLabel(S l10n, BudgetCategory category) => switch (category) {
  BudgetCategory.household => l10n.budgetCategoryHousehold,
  BudgetCategory.insurance => l10n.budgetCategoryInsurance,
  BudgetCategory.carAndTransport => l10n.budgetCategoryCar,
  BudgetCategory.subscriptions => l10n.budgetCategorySubscriptions,
  BudgetCategory.loansAndCommitments => l10n.budgetCategoryLoans,
  BudgetCategory.communications => l10n.budgetCategoryCommunications,
  BudgetCategory.healthAndEducation => l10n.budgetCategoryHealth,
  BudgetCategory.other => l10n.budgetCategoryOther,
};

IconData categoryIcon(BudgetCategory category) => switch (category) {
  BudgetCategory.household => Icons.home_outlined,
  BudgetCategory.insurance => Icons.verified_user_outlined,
  BudgetCategory.carAndTransport => Icons.directions_car_outlined,
  BudgetCategory.subscriptions => Icons.subscriptions_outlined,
  BudgetCategory.loansAndCommitments => Icons.account_balance_outlined,
  BudgetCategory.communications => Icons.wifi_outlined,
  BudgetCategory.healthAndEducation => Icons.local_hospital_outlined,
  BudgetCategory.other => Icons.category_outlined,
};

/// Slice colours for the donut. Distinct hues, dark-theme friendly; the
/// remainder slice uses the theme's gold instead of this list.
const List<Color> categorySliceColors = <Color>[
  Color(0xFF7C5CC4),
  Color(0xFF4ECBA5),
  Color(0xFFE8734A),
  Color(0xFF5B8FD6),
  Color(0xFFD667A6),
  Color(0xFF6FBF5B),
  Color(0xFFC9A227),
  Color(0xFF8C7A6B),
];
