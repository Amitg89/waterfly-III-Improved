import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/extensions.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';
import 'package:waterflyiii/israeli/accounts_service.dart';
import 'package:waterflyiii/israeli/transaction_row.dart';
import 'package:waterflyiii/pages/home/cards/card_detail.dart';
import 'package:waterflyiii/settings.dart';
import 'package:waterflyiii/theme.dart';

class HomeCards extends StatefulWidget {
  const HomeCards({super.key});

  @override
  State<HomeCards> createState() => _HomeCardsState();
}

class _HomeCardsState extends State<HomeCards>
    with AutomaticKeepAliveClientMixin {
  final Logger log = Logger("Pages.Home.Cards");

  late Future<List<AccountRead>> _cardsFuture;
  Map<String, Future<double>> _chargeFutures = <String, Future<double>>{};
  late ({DateTime start, DateTime end}) _cycle;

  @override
  void initState() {
    super.initState();
    _cardsFuture = _fetchCards();
  }

  @override
  bool get wantKeepAlive => true;

  Future<List<AccountRead>> _fetchCards() async {
    final FireflyIii api = context.read<FireflyService>().api;
    // Compute the cycle once per (re)load.
    _cycle = currentCycle(
      DateTime.now(),
      context.read<SettingsProvider>().creditCardCycleDay,
    );
    final List<AccountRead> cards = await fetchCreditCardAccounts(api);
    // Kick off all upcoming-charge fetches concurrently; each row renders its
    // own progress placeholder until its future completes.
    final Map<String, Future<double>> chargeFutures =
        <String, Future<double>>{};
    for (final AccountRead card in cards) {
      chargeFutures[card.id] = fetchUpcomingCharge(
        api,
        card.id,
        _cycle.start,
        _cycle.end,
      );
    }
    _chargeFutures = chargeFutures;
    return cards;
  }

  Future<void> _refresh() async {
    final Future<List<AccountRead>> future = _fetchCards();
    setState(() {
      _cardsFuture = future;
    });
    try {
      await future;
    } catch (_) {
      // Error is surfaced by the FutureBuilder.
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    log.fine(() => "build()");

    return FutureBuilder<List<AccountRead>>(
      future: _cardsFuture,
      builder: (
        BuildContext context,
        AsyncSnapshot<List<AccountRead>> snapshot,
      ) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          log.severe(
            "error fetching credit cards",
            snapshot.error,
            snapshot.stackTrace,
          );
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  Icons.error_outline,
                  size: 64,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  S.of(context).errorUnknown,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _refresh,
                  child: Text(S.of(context).generalRetry),
                ),
              ],
            ),
          );
        }
        final List<AccountRead> cards = snapshot.data!;
        return RefreshIndicator(
          onRefresh: _refresh,
          child:
              cards.isEmpty
                  ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: <Widget>[
                      const SizedBox(height: 128),
                      Center(child: Text(S.of(context).cardsNoCards)),
                    ],
                  )
                  : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: cards.length,
                    itemBuilder:
                        (BuildContext context, int index) =>
                            _cardRow(context, cards[index], index),
                  ),
        );
      },
    );
  }

  String _last4(AccountRead account) {
    final String number = account.attributes.accountNumber ?? "";
    return number.length >= 4 ? number.substring(number.length - 4) : number;
  }

  /// Full-width vault card face: dark gradient, sheen, gold chip, name and
  /// last-4 on the start side, upcoming charge on the end side.
  Widget _cardRow(BuildContext context, AccountRead card, int index) {
    final CurrencyRead currency = currencyFromAccount(context, card);
    final String last4 = _last4(card);
    final MoneyColors mc = Theme.of(context).extension<MoneyColors>()!;
    final int gradientIndex = index % mc.cardGradients.length;
    final List<Color> gradient = mc.cardGradients[gradientIndex];
    final Color faceFg = mc.cardFaceForeground;

    return Container(
      height: 96,
      margin: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: gradient,
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        children: <Widget>[
          // Subtle radial sheen in the top-end corner.
          PositionedDirectional(
            top: -24,
            end: -24,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[faceFg.withAlpha(0x24), faceFg.withAlpha(0)],
                ),
              ),
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap:
                  () => showCardSheet(
                    context,
                    account: card,
                    prevCharge: _cycle.start,
                    nextCharge: _cycle.end,
                    gradientIndex: gradientIndex,
                  ),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          // Gold chip rectangle.
                          Container(
                            width: 26,
                            height: 19,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(5),
                              gradient: LinearGradient(
                                colors: mc.heroGradient.length >= 2
                                    ? <Color>[mc.heroGradient[1], mc.goldDeep]
                                    : <Color>[mc.goldDeep, mc.goldDeep],
                              ),
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                card.attributes.name,
                                style: TextStyle(
                                  color: faceFg.withAlpha(0xB2), // ~70 %
                                  fontSize: 11,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '•••• $last4',
                                style: TextStyle(
                                  color: faceFg,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 2.5,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _chargeColumn(context, card, currency, faceFg),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Trailing upcoming-charge treatment: prominent light-on-dark amount plus
  /// the "Charge on {date}" caption.
  Widget _chargeColumn(
    BuildContext context,
    AccountRead card,
    CurrencyRead currency,
    Color faceFg,
  ) {
    return FutureBuilder<double>(
      future: _chargeFutures[card.id],
      builder: (BuildContext context, AsyncSnapshot<double> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: faceFg),
          );
        }
        if (snapshot.hasError) {
          log.severe(
            "error fetching upcoming charge for ${card.id}",
            snapshot.error,
            snapshot.stackTrace,
          );
          return Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.error,
          );
        }
        final double charge = snapshot.data!;
        return Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Text(
              currency.fmt(charge),
              style: TextStyle(
                color: faceFg,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                fontFeatures: const <FontFeature>[
                  FontFeature.tabularFigures(),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              S.of(context).cardsChargeOn(DateFormat.yMd().format(_cycle.end)),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: faceFg.withAlpha(0xA8), // ~66 %
              ),
            ),
          ],
        );
      },
    );
  }
}
