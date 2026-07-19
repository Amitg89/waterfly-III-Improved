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
import 'package:waterflyiii/widgets/vault_sheet.dart';

final Logger log = Logger("Pages.Home.Banks.Detail");

/// Opens the bank-account detail bottom sheet: a fixed header with the
/// current balance (never affected by filters) and a transaction list below —
/// by default the last 15 transactions, or all transactions within a
/// user-picked date range.
Future<void> showBankSheet(
  BuildContext context, {
  required AccountRead account,
}) {
  return showVaultSheet<void>(
    context: context,
    builder:
        (BuildContext sheetContext, ScrollController scrollController) =>
            BankSheetContent(
              account: account,
              scrollController: scrollController,
            ),
  );
}

/// Sheet body for a single bank account. Kept as a public widget so it can
/// be hosted by [showBankSheet]; all data logic (default last-15 fetch vs.
/// date-range fetch) lives here.
class BankSheetContent extends StatefulWidget {
  const BankSheetContent({
    super.key,
    required this.account,
    required this.scrollController,
  });

  final AccountRead account;
  final ScrollController scrollController;

  @override
  State<BankSheetContent> createState() => _BankSheetContentState();
}

class _BankSheetContentState extends State<BankSheetContent> {
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
    final MoneyColors mc = Theme.of(context).extension<MoneyColors>()!;
    final S l10n = S.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Fixed header: current balance. Never changes when filters change.
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.account.attributes.name,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.banksCurrentBalance.toUpperCase(),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      currency.fmt(balance),
                      style: Theme.of(
                        context,
                      ).textTheme.headlineMedium?.copyWith(
                        color: balance < 0 ? mc.negative : mc.positive,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _rangePill(context, l10n),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _body(context)),
      ],
    );
  }

  /// Date pill: filters ONLY the transaction list; shows the picker label by
  /// default or the active range with a clear affordance.
  Widget _rangePill(BuildContext context, S l10n) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String label = _range == null
        ? l10n.homeTransactionsDialogFilterDateRange
        : "${DateFormat.yMd().format(_range!.start)}"
            " – ${DateFormat.yMd().format(_range!.end)}";

    return Material(
      color: cs.surfaceContainerHighest,
      shape: StadiumBorder(side: BorderSide(color: cs.outline, width: 1)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _pickRange,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.calendar_today_outlined, size: 15, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_range != null) ...<Widget>[
                const SizedBox(width: 6),
                Tooltip(
                  message: l10n.generalClearFilter,
                  child: InkWell(
                    onTap: _clearRange,
                    customBorder: const CircleBorder(),
                    child: Icon(Icons.close, size: 15, color: cs.primary),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return FutureBuilder<List<TransactionRead>>(
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
          return ListView(
            controller: widget.scrollController,
            children: <Widget>[
              const SizedBox(height: 32),
              Center(child: Text(S.of(context).errorUnknown)),
              const SizedBox(height: 8),
              Center(
                child: FilledButton(
                  onPressed: _refetch,
                  child: Text(S.of(context).generalRetry),
                ),
              ),
            ],
          );
        }
        final List<TransactionRead> transactions = snapshot.data!;
        if (transactions.isEmpty) {
          return ListView(
            controller: widget.scrollController,
            children: <Widget>[
              const SizedBox(height: 32),
              Center(child: Text(S.of(context).homeTransactionsEmpty)),
            ],
          );
        }
        return ListView.builder(
          controller: widget.scrollController,
          itemCount: transactions.length,
          itemBuilder:
              (BuildContext context, int index) =>
                  israeliTransactionRow(context, transactions[index]),
        );
      },
    );
  }
}
