import 'package:flutter/material.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';

class HomeBanks extends StatelessWidget {
  const HomeBanks({super.key});

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.account_balance_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            l10n.comingSoonTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.comingSoonSubtitle,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
