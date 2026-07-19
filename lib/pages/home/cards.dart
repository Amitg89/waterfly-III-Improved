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
                            _cardRow(context, cards[index]),
                  ),
        );
      },
    );
  }

  String _last4(AccountRead account) {
    final String number = account.attributes.accountNumber ?? "";
    return number.length >= 4 ? number.substring(number.length - 4) : number;
  }

  Widget _cardRow(BuildContext context, AccountRead card) {
    final CurrencyRead currency = currencyFromAccount(context, card);
    final String last4 = _last4(card);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.credit_card)),
        title: Text(
          card.attributes.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: last4.isNotEmpty ? Text("•••• $last4") : null,
        trailing: FutureBuilder<double>(
          future: _chargeFutures[card.id],
          builder: (BuildContext context, AsyncSnapshot<double> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
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
                  style: Theme.of(context).textTheme.titleMedium!.copyWith(
                    color: charge < 0
                        ? Theme.of(context).extension<MoneyColors>()!.positive
                        : Theme.of(context).extension<MoneyColors>()!.negative,
                    fontWeight: FontWeight.bold,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                Text(
                  S
                      .of(context)
                      .cardsChargeOn(DateFormat.yMd().format(_cycle.end)),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            );
          },
        ),
        onTap:
            () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder:
                    (BuildContext context) => CardDetailPage(
                      account: card,
                      prevCharge: _cycle.start,
                      nextCharge: _cycle.end,
                    ),
              ),
            ),
      ),
    );
  }
}
