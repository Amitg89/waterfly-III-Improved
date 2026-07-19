import 'package:chopper/chopper.dart' show Response;
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

final Logger log = Logger("Pages.Home.Cards.Detail");

/// Detail page for a credit card: a header with the upcoming charge and the
/// cycle's transactions below. When the user picks a custom date range, both
/// the list and the header switch to a "total for period" view based on the
/// purchase date (which matches the intuition of "what did I spend between
/// X and Y"); the cycle view uses the billing date (process_date).
class CardDetailPage extends StatefulWidget {
  const CardDetailPage({
    super.key,
    required this.account,
    required this.prevCharge,
    required this.nextCharge,
  });

  final AccountRead account;
  final DateTime prevCharge;
  final DateTime nextCharge;

  @override
  State<CardDetailPage> createState() => _CardDetailPageState();
}

class _CardDetailPageState extends State<CardDetailPage> {
  static const int _pageLimit = 50;
  static const int _maxPages = 100;

  DateTimeRange? _range;
  late Future<List<TransactionRead>> _txFuture;

  @override
  void initState() {
    super.initState();
    _txFuture = _fetch();
  }

  Future<List<TransactionRead>> _fetch() async {
    final FireflyIii api = context.read<FireflyService>().api;
    if (_range == null) {
      // Cycle view: filtered by billing date (process_date).
      return fetchCycleTransactions(
        api,
        widget.account.id,
        widget.prevCharge,
        widget.nextCharge,
      );
    }

    // Custom range view: filtered by purchase date via the account
    // transactions endpoint; transfers (bank paying the card bill) are
    // excluded, like in the cycle view.
    final DateFormat fmt = DateFormat('yyyy-MM-dd', 'en_US');
    final List<TransactionRead> transactions = <TransactionRead>[];
    int page = 1;
    while (page <= _maxPages) {
      final Response<TransactionArray> response = await api
          .v1AccountsIdTransactionsGet(
            id: widget.account.id,
            page: page,
            limit: _pageLimit,
            start: fmt.format(_range!.start),
            end: fmt.format(_range!.end),
          );
      apiThrowErrorIfEmpty(response, mounted ? context : null);
      final List<TransactionRead> data = response.body!.data;
      transactions.addAll(data);
      final int? totalPages = response.body!.meta.pagination?.totalPages;
      if (data.length < _pageLimit ||
          (totalPages != null && page >= totalPages)) {
        break;
      }
      page++;
    }
    final List<TransactionRead> filtered =
        transactions.where((TransactionRead transaction) {
          final List<TransactionSplit> splits =
              transaction.attributes.transactions;
          if (splits.isEmpty) {
            return false;
          }
          return splits.first.type == TransactionTypeProperty.withdrawal ||
              splits.first.type == TransactionTypeProperty.deposit;
        }).toList();
    filtered.sort(
      (TransactionRead a, TransactionRead b) => b
          .attributes
          .transactions
          .first
          .date
          .compareTo(a.attributes.transactions.first.date),
    );
    return filtered;
  }

  void _refetch() {
    setState(() {
      _txFuture = _fetch();
    });
  }

  Future<void> _pickRange() async {
    log.finest(() => "picking date range");
    final DateTimeRange? range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 366)),
      initialDateRange: _range,
    );
    if (range == null) {
      return;
    }
    _range = range;
    _refetch();
  }

  void _clearRange() {
    _range = null;
    _refetch();
  }

  /// Withdrawals positive, deposits (refunds) negative; transfers were
  /// already excluded from the list.
  double _total(List<TransactionRead> transactions) {
    double sum = 0;
    for (final TransactionRead transaction in transactions) {
      for (final TransactionSplit split
          in transaction.attributes.transactions) {
        final double amount = double.tryParse(split.amount) ?? 0;
        if (split.type == TransactionTypeProperty.withdrawal) {
          sum += amount;
        } else if (split.type == TransactionTypeProperty.deposit) {
          sum -= amount;
        }
      }
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final CurrencyRead currency = currencyFromAccount(context, widget.account);
    final S l10n = S.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.account.attributes.name),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.date_range),
            tooltip: l10n.homeTransactionsDialogFilterDateRange,
            onPressed: _pickRange,
          ),
        ],
      ),
      body: FutureBuilder<List<TransactionRead>>(
        future: _txFuture,
        builder: (
          BuildContext context,
          AsyncSnapshot<List<TransactionRead>> snapshot,
        ) {
          final bool done = snapshot.connectionState == ConnectionState.done;
          final List<TransactionRead>? transactions =
              done && !snapshot.hasError ? snapshot.data : null;
          if (done && snapshot.hasError) {
            log.severe(
              "error fetching card transactions",
              snapshot.error,
              snapshot.stackTrace,
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(context, currency, transactions),
              if (_range != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: InputChip(
                      avatar: const Icon(Icons.filter_alt),
                      label: Text(
                        "${DateFormat.yMd().format(_range!.start)}"
                        " – ${DateFormat.yMd().format(_range!.end)}",
                      ),
                      deleteButtonTooltipMessage: l10n.generalClearFilter,
                      onDeleted: _clearRange,
                    ),
                  ),
                ),
              Expanded(child: _body(context, snapshot, transactions)),
            ],
          );
        },
      ),
    );
  }

  Widget _header(
    BuildContext context,
    CurrencyRead currency,
    List<TransactionRead>? transactions,
  ) {
    final S l10n = S.of(context);
    final double? total = transactions != null ? _total(transactions) : null;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _range == null
                  ? l10n.cardsUpcomingCharge
                  : l10n.cardsTotalForPeriod,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            total == null
                ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : Text(
                  currency.fmt(total),
                  style: Theme.of(context).textTheme.headlineMedium!.copyWith(
                    color: total < 0 ? Colors.green : Colors.red,
                    fontWeight: FontWeight.bold,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
            if (_range == null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                l10n.cardsChargeOn(DateFormat.yMd().format(widget.nextCharge)),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AsyncSnapshot<List<TransactionRead>> snapshot,
    List<TransactionRead>? transactions,
  ) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(S.of(context).errorUnknown),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _refetch,
              child: Text(S.of(context).generalRetry),
            ),
          ],
        ),
      );
    }
    if (transactions == null || transactions.isEmpty) {
      return Center(child: Text(S.of(context).homeTransactionsEmpty));
    }
    return ListView.builder(
      itemCount: transactions.length,
      itemBuilder:
          (BuildContext context, int index) => israeliTransactionRow(
            context,
            transactions[index],
            showBilledCaption: true,
          ),
    );
  }
}
