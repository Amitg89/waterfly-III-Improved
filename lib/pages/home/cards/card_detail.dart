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
import 'package:waterflyiii/theme.dart';
import 'package:waterflyiii/widgets/vault_sheet.dart';

final Logger log = Logger("Pages.Home.Cards.Detail");

/// Opens the credit-card detail bottom sheet: a gradient card-face header,
/// the upcoming charge (or a custom-period total) and the cycle's
/// transactions below. When the user picks a custom date range, both the
/// list and the header switch to a "total for period" view based on the
/// purchase date (which matches the intuition of "what did I spend between
/// X and Y"); the cycle view uses the billing date (process_date).
///
/// [gradientIndex] selects the card-face gradient so the sheet header matches
/// the row/carousel face the user tapped.
Future<void> showCardSheet(
  BuildContext context, {
  required AccountRead account,
  required DateTime prevCharge,
  required DateTime nextCharge,
  required int gradientIndex,
}) {
  return showVaultSheet<void>(
    context: context,
    builder:
        (BuildContext sheetContext, ScrollController scrollController) =>
            CardSheetContent(
              account: account,
              prevCharge: prevCharge,
              nextCharge: nextCharge,
              gradientIndex: gradientIndex,
              scrollController: scrollController,
            ),
  );
}

/// Sheet body for a single credit card. Kept as a public widget so it can be
/// hosted by [showCardSheet]; all data logic (cycle fetch vs. date-range
/// fetch, header total recomputed from the list) lives here.
class CardSheetContent extends StatefulWidget {
  const CardSheetContent({
    super.key,
    required this.account,
    required this.prevCharge,
    required this.nextCharge,
    required this.gradientIndex,
    required this.scrollController,
  });

  final AccountRead account;
  final DateTime prevCharge;
  final DateTime nextCharge;
  final int gradientIndex;
  final ScrollController scrollController;

  @override
  State<CardSheetContent> createState() => _CardSheetContentState();
}

class _CardSheetContentState extends State<CardSheetContent> {
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

  String _last4() {
    final String number = widget.account.attributes.accountNumber ?? "";
    if (number.length >= 4) {
      return number.substring(number.length - 4);
    }
    final String name = widget.account.attributes.name;
    if (name.length >= 4) {
      final String tail = name.substring(name.length - 4);
      if (RegExp(r'^\d{4}$').hasMatch(tail)) {
        return tail;
      }
    }
    return number;
  }

  @override
  Widget build(BuildContext context) {
    final CurrencyRead currency = currencyFromAccount(context, widget.account);
    final S l10n = S.of(context);

    return FutureBuilder<List<TransactionRead>>(
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
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 0),
              child: _cardFace(context),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 0),
              child: Text(
                (_range == null
                        ? "${l10n.cardsUpcomingCharge}"
                            " · ${DateFormat.yMd().format(widget.nextCharge)}"
                        : l10n.cardsTotalForPeriod)
                    .toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  letterSpacing: 1.0,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(child: _totalText(context, currency, transactions)),
                  const SizedBox(width: 8),
                  _rangePill(context, l10n),
                ],
              ),
            ),
            Expanded(child: _body(context, snapshot, transactions)),
          ],
        );
      },
    );
  }

  /// Gradient card-face header matching the row/carousel face that was
  /// tapped (same gradient index).
  Widget _cardFace(BuildContext context) {
    final MoneyColors mc = Theme.of(context).extension<MoneyColors>()!;
    final List<Color> gradient =
        mc.cardGradients[widget.gradientIndex % mc.cardGradients.length];
    final Color faceFg = mc.cardFaceForeground;
    final String last4 = _last4();

    return Container(
      height: 150,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
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
            top: -36,
            end: -36,
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[faceFg.withAlpha(0x24), faceFg.withAlpha(0)],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(18, 16, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                // Gold chip rectangle.
                Container(
                  width: 30,
                  height: 22,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
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
                      widget.account.attributes.name,
                      style: TextStyle(
                        color: faceFg.withAlpha(0xB2), // ~70 %
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '•••• $last4',
                      style: TextStyle(
                        color: faceFg,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 2.5,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Big total for the current view (upcoming charge or period total).
  Widget _totalText(
    BuildContext context,
    CurrencyRead currency,
    List<TransactionRead>? transactions,
  ) {
    final MoneyColors mc = Theme.of(context).extension<MoneyColors>()!;
    final double? total = transactions != null ? _total(transactions) : null;
    if (total == null) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Text(
      currency.fmt(total),
      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
        color: total < 0 ? mc.positive : mc.negative,
        fontSize: 30,
        fontWeight: FontWeight.w700,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// Date pill: shows "This cycle" (default) or the active custom range with
  /// a clear affordance. Tapping it opens the existing date-range picker.
  Widget _rangePill(BuildContext context, S l10n) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String label = _range == null
        ? l10n.cardsThisCycle
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

  Widget _body(
    BuildContext context,
    AsyncSnapshot<List<TransactionRead>> snapshot,
    List<TransactionRead>? transactions,
  ) {
    if (snapshot.connectionState != ConnectionState.done) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.hasError) {
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
    if (transactions == null || transactions.isEmpty) {
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
          (BuildContext context, int index) => israeliTransactionRow(
            context,
            transactions[index],
            showBilledCaption: true,
          ),
    );
  }
}
