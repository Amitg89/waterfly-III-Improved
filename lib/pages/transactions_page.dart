import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/pages/home.dart';
import 'package:waterflyiii/pages/home/transactions.dart';
import 'package:waterflyiii/pages/navigation.dart';
import 'package:waterflyiii/widgets/fabs.dart';

/// Standalone wrapper for [HomeTransactions] used as a top-level nav destination.
///
/// Provides the [PageActions] notifier that [HomeTransactions] uses to register
/// its filter/tag action buttons, and wires those actions into [NavPageElements]
/// (the shared AppBar actions managed by [NavPage]).
class TransactionsPage extends StatefulWidget {
  const TransactionsPage({super.key});

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  final PageActions _actions = PageActions();

  @override
  void initState() {
    super.initState();

    _actions.addListener(_syncActions);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      // Set the FAB for the transactions page
      final Widget fab = NewTransactionFab(context: context);
      context.read<NavPageElements>().fab = fab;
      context.read<NavPageElements>().appBarTitle =
          Text(S.of(context).homeTabLabelTransactions);
    });
  }

  void _syncActions() {
    if (!context.mounted) return;
    final List<Widget>? actions =
        _actions.get(const Key('HomeTransactions'));
    context.read<NavPageElements>().appBarActions = actions;
  }

  @override
  void dispose() {
    _actions.removeListener(_syncActions);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<PageActions>.value(
      value: _actions,
      child: const HomeTransactions(key: Key('HomeTransactions')),
    );
  }
}
