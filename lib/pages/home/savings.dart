import 'package:flutter/material.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/theme.dart';

class HomeSavings extends StatelessWidget {
  const HomeSavings({super.key});

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final MoneyColors mc = Theme.of(context).extension<MoneyColors>()!;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: cs.outline, width: 1),
          ),
          color: cs.surface,
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Heroic gold accent strip at the top.
              Container(
                height: 3,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: mc.heroGradient,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 28, 28, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.savings_outlined,
                      size: 64,
                      color: mc.goldDeep,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.comingSoonTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.comingSoonSubtitle,
                      style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
