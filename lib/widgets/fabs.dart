import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/pages/transaction.dart';

class NewTransactionFab extends StatelessWidget {
  const NewTransactionFab({super.key, required this.context, this.accountId});

  final BuildContext context;
  final String? accountId;

  @override
  Widget build(BuildContext context) {
    return OpenContainer(
      openBuilder: (BuildContext context, Function closedContainer) {
        return TransactionPage(accountId: accountId);
      },
      openColor: Theme.of(context).colorScheme.surface,
      // Gold circle: primary is gold in vault themes; CircleBorder prevents
      // the RoundedRectangleBorder from painting a pale square over the FAB.
      closedColor: Theme.of(context).colorScheme.primary,
      closedShape: const CircleBorder(),
      closedElevation: 4,
      closedBuilder: (BuildContext context, Function openContainer) {
        return SizedBox(
          width: 56,
          height: 56,
          child: FloatingActionButton(
            onPressed: () => openContainer(),
            tooltip: S.of(context).formButtonTransactionAdd,
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            elevation: 0,
            child: const Icon(Icons.add),
          ),
        );
      },
      onClosed: (bool? refresh) {
        if (refresh ?? false == true) {
          if (context.mounted) {
            context.read<FireflyService>().transStock!.clear();
          }
        }
      },
    );
  }
}
