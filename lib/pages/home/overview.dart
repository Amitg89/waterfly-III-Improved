import 'dart:async';

import 'package:chopper/chopper.dart' show Response;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/extensions.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';
import 'package:waterflyiii/israeli/accounts_service.dart';
import 'package:waterflyiii/settings.dart';
import 'package:waterflyiii/widgets/charts.dart';

final Logger _log = Logger("Pages.Home.Overview");

// ---------------------------------------------------------------------------
// Coordinating data loader
// ---------------------------------------------------------------------------

/// Per-account upcoming-charge data computed from cycle transactions.
class _CardCharge {
  _CardCharge({
    required this.account,
    required this.charge,
    required this.transactions,
  });
  final AccountRead account;
  final double charge;
  final List<TransactionRead> transactions;
}

/// All data needed by the four overview cards, fetched once and shared.
class _OverviewData {
  _OverviewData({
    required this.bankAccounts,
    required this.cardCharges,
    required this.incomePerMonth,
  });

  /// defaultAsset accounts.
  final List<AccountRead> bankAccounts;

  /// One entry per credit card; includes the full list of cycle transactions
  /// so card 3 (upcoming by card) and card 4 (by category) can share them.
  final List<_CardCharge> cardCharges;

  /// Income by month: list of 5 entries, oldest first.
  /// Each entry: (monthStart, totalIncome).
  final List<({DateTime month, double income})> incomePerMonth;
}

/// Builds the last 5 calendar months (current + 4 previous), oldest first.
List<({DateTime start, DateTime end})> _last5MonthWindows(DateTime now) {
  final List<({DateTime start, DateTime end})> windows = <({
    DateTime start,
    DateTime end,
  })>[];
  for (int i = 4; i >= 0; i--) {
    // Subtract i months from the current month.
    final DateTime ms = DateTime(now.year, now.month - i, 1);
    final DateTime me = DateTime(now.year, now.month - i + 1, 1)
        .subtract(const Duration(days: 1));
    // For the current month cap end at today.
    final DateTime end = (i == 0 && now.isBefore(me)) ? now : me;
    windows.add((start: ms, end: end));
  }
  return windows;
}

Future<_OverviewData> _loadOverviewData(
  FireflyIii api,
  int cycleDay,
) async {
  // 1. Fetch bank accounts and credit cards concurrently.
  final (
    List<AccountRead> bankAccounts,
    List<AccountRead> cards,
  ) = await (
    fetchBankAccounts(api),
    fetchCreditCardAccounts(api),
  ).wait;

  // 2. Build cycle window.
  final ({DateTime start, DateTime end}) cycle = currentCycle(
    DateTime.now(),
    cycleDay,
  );

  // 3. Fetch cycle transactions for every card concurrently.
  final List<Future<List<TransactionRead>>> cycleFutures = cards
      .map(
        (AccountRead card) => fetchCycleTransactions(
          api,
          card.id,
          cycle.start,
          cycle.end,
        ),
      )
      .toList();
  final List<List<TransactionRead>> cycleTxLists = await Future.wait(
    cycleFutures,
  );

  // 4. Build _CardCharge list: compute charge from transactions (no extra call).
  //    charge = withdrawals − deposits (same logic as fetchUpcomingCharge).
  final List<_CardCharge> cardCharges = <_CardCharge>[];
  for (int i = 0; i < cards.length; i++) {
    final List<TransactionRead> txs = cycleTxLists[i];
    double charge = 0;
    for (final TransactionRead tx in txs) {
      for (final TransactionSplit split in tx.attributes.transactions) {
        final bool isCardType =
            split.type == TransactionTypeProperty.withdrawal ||
            split.type == TransactionTypeProperty.deposit;
        if (!isCardType) continue;
        final double amount = double.tryParse(split.amount) ?? 0;
        charge +=
            split.type == TransactionTypeProperty.withdrawal
                ? amount
                : -amount;
      }
    }
    cardCharges.add(
      _CardCharge(account: cards[i], charge: charge, transactions: txs),
    );
  }

  // 5. Fetch income for last 5 months using v1InsightIncomeAssetGet.
  //    Pass the bank account IDs so we only get deposits into bank accounts.
  final List<int> bankIds =
      bankAccounts
          .map((AccountRead a) => int.tryParse(a.id))
          .whereType<int>()
          .toList();

  final DateTime now = DateTime.now();
  final List<({DateTime start, DateTime end})> monthWindows =
      _last5MonthWindows(now);
  final DateFormat dateFmt = DateFormat('yyyy-MM-dd', 'en_US');

  final List<Future<Response<InsightGroup>>> incomeFutures =
      monthWindows
          .map(
            (({DateTime start, DateTime end}) w) =>
                api.v1InsightIncomeAssetGet(
                  start: dateFmt.format(w.start),
                  end: dateFmt.format(w.end),
                  accounts: bankIds.isEmpty ? null : bankIds,
                ),
          )
          .toList();
  final List<Response<InsightGroup>> incomeResponses =
      await Future.wait(incomeFutures);

  final List<({DateTime month, double income})> incomePerMonth =
      <({DateTime month, double income})>[];
  for (int i = 0; i < monthWindows.length; i++) {
    final Response<InsightGroup> resp = incomeResponses[i];
    double total = 0;
    if (resp.isSuccessful && resp.body != null) {
      for (final InsightGroupEntry entry in resp.body!) {
        total += (entry.differenceFloat ?? 0).abs();
      }
    }
    incomePerMonth.add((month: monthWindows[i].start, income: total));
  }

  return _OverviewData(
    bankAccounts: bankAccounts,
    cardCharges: cardCharges,
    incomePerMonth: incomePerMonth,
  );
}

// ---------------------------------------------------------------------------
// Main widget
// ---------------------------------------------------------------------------

class HomeOverview extends StatefulWidget {
  const HomeOverview({
    super.key,
    this.onNavigateToCards,
  });

  /// Called when the user taps card 3 (upcoming charges); should switch to
  /// the Cards tab.
  final void Function()? onNavigateToCards;

  @override
  State<HomeOverview> createState() => _HomeOverviewState();
}

class _HomeOverviewState extends State<HomeOverview>
    with AutomaticKeepAliveClientMixin {
  Future<_OverviewData>? _dataFuture;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _dataFuture = _load();
  }

  Future<_OverviewData> _load() {
    final FireflyIii api = context.read<FireflyService>().api;
    final int cycleDay =
        context.read<SettingsProvider>().creditCardCycleDay;
    return _loadOverviewData(api, cycleDay);
  }

  Future<void> _refresh() async {
    final Future<_OverviewData> future = _load();
    setState(() {
      _dataFuture = future;
    });
    try {
      await future;
    } catch (e, st) {
      _log.warning("refresh error", e, st);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _log.finest("build()");

    return RefreshIndicator(
      onRefresh: _refresh,
      child: FutureBuilder<_OverviewData>(
        future: _dataFuture,
        builder: (
          BuildContext context,
          AsyncSnapshot<_OverviewData> snapshot,
        ) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _buildError(snapshot.error!);
          }
          final _OverviewData data = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(8),
            children: <Widget>[
              _IncomeCard(data: data),
              const SizedBox(height: 4),
              _AvailableMoneyCard(data: data),
              const SizedBox(height: 4),
              _UpcomingChargesCard(
                data: data,
                onTap: widget.onNavigateToCards,
              ),
              const SizedBox(height: 4),
              _UpcomingByCategoryCard(data: data),
              const SizedBox(height: 68),
            ],
          );
        },
      ),
    );
  }

  Widget _buildError(Object error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(S.of(context).overviewErrorRetry),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _refresh,
              child: Text(S.of(context).generalRetry),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Compact amount label: "₪12.3K", "₪1.2M", or full for small values.
String _compactAmount(CurrencyRead currency, double amount) {
  final double abs = amount.abs();
  if (abs >= 1000000) {
    final double m = amount / 1000000;
    return '${currency.attributes.symbol}${m.toStringAsFixed(1)}M';
  }
  if (abs >= 1000) {
    final double k = amount / 1000;
    return '${currency.attributes.symbol}${k.toStringAsFixed(1)}K';
  }
  return currency.fmt(amount);
}

/// Builds the standard card shell used by all four overview cards.
Widget _overviewCard({
  required BuildContext context,
  required String title,
  required Widget child,
  VoidCallback? onTap,
}) {
  return Card(
    clipBehavior: Clip.hardEdge,
    margin: const EdgeInsets.fromLTRB(4, 4, 4, 4),
    child: InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          child,
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Gets the last-4 digits from an account name if it ends with exactly 4 digits,
/// otherwise returns the full name.
String _cardLast4(String name) {
  if (name.length >= 4) {
    final String last4 = name.substring(name.length - 4);
    if (RegExp(r'^\d{4}$').hasMatch(last4)) return last4;
  }
  return name;
}

CurrencyRead _currencyFromAccount(AccountRead account) => CurrencyRead(
      id: account.attributes.currencyId ?? '0',
      type: 'currencies',
      attributes: CurrencyProperties(
        code: account.attributes.currencyCode ?? '',
        name: account.attributes.currencyName ?? '',
        symbol: account.attributes.currencySymbol ?? '',
        decimalPlaces: account.attributes.currencyDecimalPlaces,
      ),
    );

// ---------------------------------------------------------------------------
// Card 1: Income bar chart
// ---------------------------------------------------------------------------

class _IncomeCard extends StatelessWidget {
  const _IncomeCard({required this.data});
  final _OverviewData data;

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;

    if (data.incomePerMonth.isEmpty) {
      return _overviewCard(
        context: context,
        title: l10n.overviewCardIncomeTitle,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(l10n.overviewNoData),
        ),
      );
    }

    // Determine a default currency from the first bank account (fallback to
    // FireflyService.defaultCurrency).
    final CurrencyRead defaultCurrency =
        context.read<FireflyService>().defaultCurrency;
    final CurrencyRead currency =
        data.bankAccounts.isNotEmpty
            ? _currencyFromAccount(data.bankAccounts.first)
            : defaultCurrency;

    final int lastIndex = data.incomePerMonth.length - 1;

    return _overviewCard(
      context: context,
      title: l10n.overviewCardIncomeTitle,
      child: SizedBox(
        height: 220,
        child: SfCartesianChart(
          plotAreaBorderWidth: 0,
          margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          primaryXAxis: CategoryAxis(
            majorGridLines: const MajorGridLines(width: 0),
            axisLine: const AxisLine(width: 0),
            labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          primaryYAxis: const NumericAxis(
            isVisible: false,
          ),
          series: <CartesianSeries<({DateTime month, double income}), String>>[
            ColumnSeries<({DateTime month, double income}), String>(
              dataSource: data.incomePerMonth,
              xValueMapper: (({DateTime month, double income}) e, _) =>
                  DateFormat.MMM().format(e.month),
              yValueMapper: (({DateTime month, double income}) e, _) =>
                  e.income,
              pointColorMapper:
                  (({DateTime month, double income}) e, int index) =>
                      index == lastIndex ? cs.primary : cs.primaryContainer,
              dataLabelMapper: (({DateTime month, double income}) e, _) =>
                  _compactAmount(currency, e.income),
              dataLabelSettings: DataLabelSettings(
                isVisible: true,
                labelAlignment: ChartDataLabelAlignment.top,
                textStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Card 2: Available money
// ---------------------------------------------------------------------------

class _AvailableMoneyCard extends StatelessWidget {
  const _AvailableMoneyCard({required this.data});
  final _OverviewData data;

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);

    if (data.bankAccounts.isEmpty) {
      return _overviewCard(
        context: context,
        title: l10n.overviewCardAvailableMoneyTitle,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(l10n.overviewNoData),
        ),
      );
    }

    // Group totals by currency code.
    final Map<String, ({CurrencyRead currency, double sum})> totals =
        <String, ({CurrencyRead currency, double sum})>{};

    final List<Widget> rows = <Widget>[];
    for (final AccountRead account in data.bankAccounts) {
      final double balance =
          double.tryParse(account.attributes.currentBalance ?? '0') ?? 0;
      final CurrencyRead currency = _currencyFromAccount(account);

      rows.add(_BalanceRow(
        label: account.attributes.name,
        balance: balance,
        currency: currency,
      ));

      final String key = currency.attributes.code;
      if (totals.containsKey(key)) {
        totals[key] = (
          currency: totals[key]!.currency,
          sum: totals[key]!.sum + balance,
        );
      } else {
        totals[key] = (currency: currency, sum: balance);
      }
    }

    // Divider + total row(s).
    final List<Widget> totalRows = totals.values.map((
      ({CurrencyRead currency, double sum}) t,
    ) {
      return _BalanceRow(
        label: l10n.generalSum,
        balance: t.sum,
        currency: t.currency,
        bold: true,
      );
    }).toList();

    return _overviewCard(
      context: context,
      title: l10n.overviewCardAvailableMoneyTitle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ...rows,
            const Divider(height: 16),
            ...totalRows,
          ],
        ),
      ),
    );
  }
}

class _BalanceRow extends StatelessWidget {
  const _BalanceRow({
    required this.label,
    required this.balance,
    required this.currency,
    this.bold = false,
  });

  final String label;
  final double balance;
  final CurrencyRead currency;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final Color amountColor = balance >= 0 ? Colors.green : Colors.red;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: bold
                  ? Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.bold)
                  : null,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            currency.fmt(balance),
            style: TextStyle(
              color: amountColor,
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              fontFeatures: const <FontFeature>[
                FontFeature.tabularFigures(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Card 3: Upcoming charges (pie, per card) — tappable to navigate to Cards tab
// ---------------------------------------------------------------------------

class _UpcomingChargesCard extends StatelessWidget {
  const _UpcomingChargesCard({
    required this.data,
    this.onTap,
  });

  final _OverviewData data;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);

    // Only cards with a nonzero upcoming charge.
    final List<_CardCharge> visible =
        data.cardCharges.where((_CardCharge c) => c.charge > 0).toList();

    if (visible.isEmpty) {
      return _overviewCard(
        context: context,
        title: l10n.overviewCardUpcomingChargesTitle,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(l10n.overviewNoData),
        ),
      );
    }

    // Build pie data.
    final List<LabelAmountChart> pieData = visible
        .map(
          (_CardCharge c) => LabelAmountChart(
            _cardLast4(c.account.attributes.name),
            c.charge,
          ),
        )
        .toList();

    // Total (group by currency).
    final Map<String, ({CurrencyRead currency, double sum})> totals =
        <String, ({CurrencyRead currency, double sum})>{};
    for (final _CardCharge c in visible) {
      final CurrencyRead currency = _currencyFromAccount(c.account);
      final String key = currency.attributes.code;
      totals[key] = (
        currency: currency,
        sum: (totals[key]?.sum ?? 0) + c.charge,
      );
    }

    // Use the first card's currency for the total display (most common case).
    final CurrencyRead totalCurrency =
        totals.values.isNotEmpty
            ? totals.values.first.currency
            : _currencyFromAccount(visible.first.account);
    final double totalSum = totals.values.fold(
      0,
      (double acc, ({CurrencyRead currency, double sum}) t) => acc + t.sum,
    );

    return _overviewCard(
      context: context,
      title: l10n.overviewCardUpcomingChargesTitle,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: 240,
            child: SfCircularChart(
              legend: Legend(
                isVisible: true,
                position: LegendPosition.bottom,
                overflowMode: LegendItemOverflowMode.wrap,
                itemPadding: 4,
                textStyle:
                    Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.normal,
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              palette: possibleChartColorsDart,
              series: <CircularSeries<LabelAmountChart, String>>[
                PieSeries<LabelAmountChart, String>(
                  dataSource: pieData,
                  xValueMapper: (LabelAmountChart d, _) => d.label,
                  yValueMapper: (LabelAmountChart d, _) => d.amount,
                  dataLabelMapper: (LabelAmountChart d, _) => d.label,
                  dataLabelSettings: DataLabelSettings(
                    isVisible: true,
                    labelPosition: ChartDataLabelPosition.outside,
                    textStyle:
                        Theme.of(context).textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.normal,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
                    connectorLineSettings: ConnectorLineSettings(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              l10n.overviewCardTotal(totalCurrency.fmt(totalSum)),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Card 4: Upcoming charges by category (pie + bottom sheet drill-down)
// ---------------------------------------------------------------------------

class _CategoryEntry {
  _CategoryEntry({
    required this.name,
    required this.total,
    required this.transactions,
  });

  final String name;
  final double total;
  /// (TransactionRead, cardLast4) pairs for this category.
  final List<({TransactionRead tx, String cardLast4})> transactions;
}

class _UpcomingByCategoryCard extends StatelessWidget {
  const _UpcomingByCategoryCard({required this.data});
  final _OverviewData data;

  /// Groups all cycle transactions from all cards by category.
  List<_CategoryEntry> _buildCategories(BuildContext context) {
    final String otherLabel = S.of(context).overviewCategoryOther;

    // accountId → last4.
    final Map<String, String> last4Map = <String, String>{
      for (final _CardCharge c in data.cardCharges)
        c.account.id: _cardLast4(c.account.attributes.name),
    };

    // category name → {total, [(tx, last4)]}.
    final Map<
      String,
      ({
        double total,
        List<({TransactionRead tx, String cardLast4})> txs,
      })
    >
    byCategory = <String, ({
      double total,
      List<({TransactionRead tx, String cardLast4})> txs,
    })>{};

    for (final _CardCharge cc in data.cardCharges) {
      final String last4 = last4Map[cc.account.id] ?? cc.account.id;
      for (final TransactionRead tx in cc.transactions) {
        for (final TransactionSplit split in tx.attributes.transactions) {
          final bool isCardType =
              split.type == TransactionTypeProperty.withdrawal ||
              split.type == TransactionTypeProperty.deposit;
          if (!isCardType) continue;

          final double amount = double.tryParse(split.amount) ?? 0;
          final double signed =
              split.type == TransactionTypeProperty.withdrawal
                  ? amount
                  : -amount;

          final String catName =
              (split.categoryName?.isNotEmpty ?? false)
                  ? split.categoryName!
                  : otherLabel;

          if (byCategory.containsKey(catName)) {
            final (
              :double total,
              :List<({TransactionRead tx, String cardLast4})> txs,
            ) = byCategory[catName]!;
            byCategory[catName] = (
              total: total + signed,
              txs: txs..add((tx: tx, cardLast4: last4)),
            );
          } else {
            byCategory[catName] = (
              total: signed,
              txs: <({TransactionRead tx, String cardLast4})>[
                (tx: tx, cardLast4: last4),
              ],
            );
          }
        }
      }
    }

    // Keep only categories with net positive spending.
    final List<_CategoryEntry> entries =
        byCategory.entries
            .where((MapEntry<String, ({
              double total,
              List<({TransactionRead tx, String cardLast4})> txs,
            })> e) => e.value.total > 0)
            .map((MapEntry<String, ({
              double total,
              List<({TransactionRead tx, String cardLast4})> txs,
            })> e) => _CategoryEntry(
              name: e.key,
              total: e.value.total,
              transactions: e.value.txs,
            ))
            .toList()
          ..sort(
            (_CategoryEntry a, _CategoryEntry b) =>
                b.total.compareTo(a.total),
          );
    return entries;
  }

  void _showCategorySheet(
    BuildContext context,
    _CategoryEntry entry,
    CurrencyRead currency,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext sheetCtx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (BuildContext _, ScrollController scrollController) =>
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // Handle bar.
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          entry.name,
                          style: Theme.of(
                            context,
                          ).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        currency.fmt(entry.total),
                        style: Theme.of(
                          context,
                        ).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: entry.transactions.length,
                    itemBuilder:
                        (BuildContext ctx, int i) =>
                            _CategoryTxRow(
                              item: entry.transactions[i],
                              currency: currency,
                            ),
                  ),
                ),
              ],
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);

    final List<_CategoryEntry> categories = _buildCategories(context);

    if (categories.isEmpty) {
      return _overviewCard(
        context: context,
        title: l10n.overviewCardUpcomingByCategoryTitle,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(l10n.overviewNoData),
        ),
      );
    }

    // Default currency: use the first card's currency.
    final CurrencyRead currency =
        data.cardCharges.isNotEmpty
            ? _currencyFromAccount(data.cardCharges.first.account)
            : context.read<FireflyService>().defaultCurrency;

    final double grandTotal = categories.fold(
      0.0,
      (double acc, _CategoryEntry e) => acc + e.total,
    );

    final List<LabelAmountChart> pieData = categories
        .map((_CategoryEntry e) => LabelAmountChart(e.name, e.total))
        .toList();

    return _overviewCard(
      context: context,
      title: l10n.overviewCardUpcomingByCategoryTitle,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: 260,
            child: SfCircularChart(
              legend: Legend(
                isVisible: true,
                position: LegendPosition.bottom,
                overflowMode: LegendItemOverflowMode.wrap,
                itemPadding: 4,
                textStyle:
                    Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.normal,
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              palette: possibleChartColorsDart,
              series: <CircularSeries<LabelAmountChart, String>>[
                PieSeries<LabelAmountChart, String>(
                  dataSource: pieData,
                  xValueMapper: (LabelAmountChart d, _) => d.label,
                  yValueMapper: (LabelAmountChart d, _) => d.amount,
                  dataLabelMapper: (LabelAmountChart d, _) => d.label,
                  dataLabelSettings: DataLabelSettings(
                    isVisible: true,
                    labelPosition: ChartDataLabelPosition.outside,
                    textStyle:
                        Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
                    connectorLineSettings: ConnectorLineSettings(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  onPointTap: (ChartPointDetails details) {
                    final int? idx = details.pointIndex;
                    if (idx == null || idx >= categories.length) return;
                    _showCategorySheet(
                      context,
                      categories[idx],
                      currency,
                    );
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              l10n.overviewCardTotal(currency.fmt(grandTotal)),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

/// One row in the category drill-down bottom sheet.
class _CategoryTxRow extends StatelessWidget {
  const _CategoryTxRow({
    required this.item,
    required this.currency,
  });

  final ({TransactionRead tx, String cardLast4}) item;
  final CurrencyRead currency;

  @override
  Widget build(BuildContext context) {
    final List<TransactionSplit> splits = item.tx.attributes.transactions;
    if (splits.isEmpty) return const SizedBox.shrink();
    final TransactionSplit split = splits.first;

    final String title =
        (item.tx.attributes.groupTitle?.isNotEmpty ?? false)
            ? item.tx.attributes.groupTitle!
            : split.description;

    double amount = 0;
    for (final TransactionSplit s in splits) {
      final double a = double.tryParse(s.amount) ?? 0;
      amount += s.type == TransactionTypeProperty.withdrawal ? a : -a;
    }

    final DateTime date = split.date.toLocal();

    return ListTile(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(DateFormat.yMMMd().format(date)),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            currency.fmt(amount),
            style: const TextStyle(
              color: Colors.red,
              fontWeight: FontWeight.w600,
              fontFeatures: <FontFeature>[
                FontFeature.tabularFigures(),
              ],
            ),
          ),
          Text(
            S.of(context).overviewCategorySheetCard(item.cardLast4),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

