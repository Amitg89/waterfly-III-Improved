import 'package:chopper/chopper.dart' show Response;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/extensions.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';
import 'package:waterflyiii/israeli/transaction_row.dart';
import 'package:waterflyiii/theme.dart';

final Logger log = Logger("Pages.Home.Banks.Detail");

/// Detail page for a bank account: a pinned header with the current balance
/// (never affected by filters) and a transaction list below — by default the
/// last 15 transactions, or all transactions within a user-picked date range.
class BankAccountDetailPage extends StatefulWidget {
  const BankAccountDetailPage({super.key, required this.account});

  final AccountRead account;

  @override
  State<BankAccountDetailPage> createState() => _BankAccountDetailPageState();
}

class _BankAccountDetailPageState extends State<BankAccountDetailPage> {
  static const int _defaultCount = 15;
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
      // Default view: latest transactions, first page only, capped at 15.
      final Response<TransactionArray> response = await api
          .v1AccountsIdTransactionsGet(
            id: widget.account.id,
            page: 1,
            limit: _defaultCount,
          );
      apiThrowErrorIfEmpty(response, mounted ? context : null);
      return response.body!.data.take(_defaultCount).toList();
    }

    // Range view: all transactions in the range, across all pages.
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
    return transactions;
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

  @override
  Widget build(BuildContext context) {
    final double balance =
        double.tryParse(widget.account.attributes.currentBalance ?? "") ?? 0;
    final CurrencyRead currency = currencyFromAccount(context, widget.account);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.account.attributes.name),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.date_range),
            tooltip: S.of(context).homeTransactionsDialogFilterDateRange,
            onPressed: _pickRange,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Header: current balance. Never changes when filters change.
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    S.of(context).banksCurrentBalance,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    currency.fmt(balance),
                    style: Theme.of(context).textTheme.headlineMedium!.copyWith(
                      color: balance < 0
                          ? Theme.of(context).extension<MoneyColors>()!.negative
                          : Theme.of(context).extension<MoneyColors>()!.positive,
                      fontWeight: FontWeight.bold,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
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
                  deleteButtonTooltipMessage: S.of(context).generalClearFilter,
                  onDeleted: _clearRange,
                ),
              ),
            ),
          Expanded(
            child: FutureBuilder<List<TransactionRead>>(
              future: _txFuture,
              builder: (
                BuildContext context,
                AsyncSnapshot<List<TransactionRead>> snapshot,
              ) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  log.severe(
                    "error fetching transactions",
                    snapshot.error,
                    snapshot.stackTrace,
                  );
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
                final List<TransactionRead> transactions = snapshot.data!;
                if (transactions.isEmpty) {
                  return Center(
                    child: Text(S.of(context).homeTransactionsEmpty),
                  );
                }
                return ListView.builder(
                  itemCount: transactions.length,
                  itemBuilder:
                      (BuildContext context, int index) =>
                          israeliTransactionRow(context, transactions[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
