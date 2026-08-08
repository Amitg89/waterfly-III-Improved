import 'package:shared_preferences/shared_preferences.dart';
import 'package:waterflyiii/israeli/budget/models.dart';

/// Persistence for the Budget tab.
///
/// Two things are stored: the last [BudgetAnalysis] (so the tab renders from
/// disk with no network wait) and the user's correction rules.
///
/// The rules matter more than they look. A correction typed into the
/// recalculate box ("the March deposit is a yearly bonus") is replayed into
/// every future run — otherwise the monthly refresh would silently forget it
/// and the same correction would have to be retyped forever.
class BudgetAnalysisStore {
  BudgetAnalysisStore({SharedPreferencesAsync? prefs})
    : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  static const String _keyAnalysis = 'budgetAnalysis';
  static const String _keyRules = 'budgetRules';

  /// How long an analysis stays fresh before the tab re-runs it on open.
  static const Duration maxAge = Duration(days: 30);

  Future<BudgetAnalysis?> readAnalysis() async =>
      BudgetAnalysis.decode(await _prefs.getString(_keyAnalysis));

  Future<void> writeAnalysis(BudgetAnalysis analysis) =>
      _prefs.setString(_keyAnalysis, analysis.encode());

  Future<List<String>> readRules() async =>
      await _prefs.getStringList(_keyRules) ?? <String>[];

  Future<List<String>> addRule(String rule) async {
    final String trimmed = rule.trim();
    if (trimmed.isEmpty) {
      return readRules();
    }
    final List<String> rules = await readRules();
    if (rules.contains(trimmed)) {
      return rules;
    }
    final List<String> updated = <String>[...rules, trimmed];
    await _prefs.setStringList(_keyRules, updated);
    return updated;
  }

  Future<List<String>> removeRule(String rule) async {
    final List<String> updated = (await readRules())
      ..removeWhere((String r) => r == rule);
    await _prefs.setStringList(_keyRules, updated);
    return updated;
  }

  Future<void> clear() async {
    await _prefs.remove(_keyAnalysis);
    await _prefs.remove(_keyRules);
  }

  static bool isStale(BudgetAnalysis? analysis, DateTime now) =>
      analysis == null || now.difference(analysis.analyzedAt) > maxAge;
}
