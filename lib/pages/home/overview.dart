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
import 'package:waterflyiii/pages/home/cards/card_detail.dart';
import 'package:waterflyiii/settings.dart';
import 'package:waterflyiii/theme.dart';
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

/// One month of income data: all deposits into the bank accounts ([total])
/// and the subset whose description matches a salary keyword ([salary]).
typedef _IncomeMonth = ({DateTime month, double total, double salary});

/// All data needed by the four overview cards, fetched once and shared.
class _OverviewData {
  _OverviewData({
    required this.bankAccounts,
    required this.cardCharges,
    required this.incomeMonths,
  });

  /// defaultAsset accounts.
  final List<AccountRead> bankAccounts;

  /// One entry per credit card; includes the full list of cycle transactions
  /// so card 3 (upcoming by card) and card 4 (by category) can share them.
  final List<_CardCharge> cardCharges;

  /// Income by month: 6 entries (current month + 5 previous), oldest first.
  final List<_IncomeMonth> incomeMonths;
}

/// Number of calendar months shown in the income chart (current + previous).
const int _incomeMonthCount = 6;

const int _incomePageLimit = 50;

// Safety net so a server bug can never make us loop forever
// (mirrors lib/israeli/accounts_service.dart).
const int _incomeMaxPages = 100;

/// Fetches all deposit transactions into [accountId] between [start] and
/// [end], paginating through every page (same break condition as the loaders
/// in lib/israeli/accounts_service.dart).
Future<List<TransactionRead>> _fetchDeposits(
  FireflyIii api,
  String accountId,
  DateTime start,
  DateTime end,
) async {
  final DateFormat fmt = DateFormat('yyyy-MM-dd', 'en_US');
  final List<TransactionRead> transactions = <TransactionRead>[];
  int page = 1;
  while (page <= _incomeMaxPages) {
    final Response<TransactionArray> response = await api
        .v1AccountsIdTransactionsGet(
          id: accountId,
          type: TransactionTypeFilter.deposit,
          start: fmt.format(start),
          end: fmt.format(end),
          page: page,
          limit: _incomePageLimit,
        );
    if (!response.isSuccessful || response.body == null) {
      _log.severe("invalid deposits response", response.error);
      throw Exception("Invalid API response: ${response.error}");
    }
    final List<TransactionRead> data = response.body!.data;
    transactions.addAll(data);
    final int? totalPages = response.body!.meta.pagination?.totalPages;
    if (data.length < _incomePageLimit ||
        (totalPages != null && page >= totalPages)) {
      break;
    }
    page++;
  }
  return transactions;
}

/// Salaries are normally deposited on the 1st-10th of the month, but around
/// holidays they can land a day or two early — i.e. on the 30th/31st of the
/// previous month. A salary deposit on such a day belongs to the NEXT month.
const int _salaryEarlyDepositDay = 30;

/// Groups deposit splits by calendar month over the last [_incomeMonthCount]
/// months (oldest first). Every deposit counts towards [_IncomeMonth.total];
/// deposits whose description contains one of [salaryKeywords]
/// (case-insensitive substring) also count towards [_IncomeMonth.salary].
///
/// Salary-matched deposits dated on/after [_salaryEarlyDepositDay] are
/// attributed to the following month (in BOTH series, so salary never
/// exceeds total within a month).
List<_IncomeMonth> _groupIncomeByMonth(
  List<TransactionRead> transactions,
  List<String> salaryKeywords,
  DateTime now,
) {
  final List<String> keywords =
      salaryKeywords.map((String k) => k.toLowerCase()).toList();

  // Month start -> (total, salary), pre-seeded so empty months show as 0.
  final Map<DateTime, ({double total, double salary})> byMonth =
      <DateTime, ({double total, double salary})>{
        for (int i = _incomeMonthCount - 1; i >= 0; i--)
          DateTime(now.year, now.month - i, 1): (total: 0, salary: 0),
      };

  for (final TransactionRead tx in transactions) {
    for (final TransactionSplit split in tx.attributes.transactions) {
      if (split.type != TransactionTypeProperty.deposit) continue;
      final DateTime date = split.date.toLocal();
      final String description = split.description.toLowerCase();
      final bool isSalary = keywords.any(
        (String k) => description.contains(k),
      );
      // Early salary (e.g. deposited 31.03 because of a holiday) belongs to
      // the next month (April).
      final DateTime month =
          (isSalary && date.day >= _salaryEarlyDepositDay)
              ? DateTime(date.year, date.month + 1, 1)
              : DateTime(date.year, date.month, 1);
      final ({double total, double salary})? entry = byMonth[month];
      if (entry == null) continue; // outside the window
      final double amount = double.tryParse(split.amount) ?? 0;
      byMonth[month] = (
        total: entry.total + amount,
        salary: entry.salary + (isSalary ? amount : 0),
      );
    }
  }

  return byMonth.entries
      .map(
        (MapEntry<DateTime, ({double total, double salary})> e) => (
          month: e.key,
          total: e.value.total,
          salary: e.value.salary,
        ),
      )
      .toList()
    ..sort((_IncomeMonth a, _IncomeMonth b) => a.month.compareTo(b.month));
}

Future<_OverviewData> _loadOverviewData(
  FireflyIii api,
  int cycleDay,
  List<String> salaryKeywords,
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

  // 5. Fetch all deposits into every bank account for the last 6 calendar
  //    months and group them by month client-side (total vs. salary).
  final DateTime now = DateTime.now();
  // Start 2 days before the oldest month so an early salary deposited on the
  // 30th/31st of the preceding month (attributed to the oldest month) is
  // included in the fetch.
  final DateTime windowStart = DateTime(
    now.year,
    now.month - (_incomeMonthCount - 1),
    1,
  ).subtract(const Duration(days: 2));

  final List<List<TransactionRead>> depositLists = await Future.wait(
    bankAccounts.map(
      (AccountRead account) =>
          _fetchDeposits(api, account.id, windowStart, now),
    ),
  );
  final List<TransactionRead> deposits =
      depositLists.expand((List<TransactionRead> l) => l).toList();

  final List<_IncomeMonth> incomeMonths = _groupIncomeByMonth(
    deposits,
    salaryKeywords,
    now,
  );

  return _OverviewData(
    bankAccounts: bankAccounts,
    cardCharges: cardCharges,
    incomeMonths: incomeMonths,
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
    final SettingsProvider settings = context.read<SettingsProvider>();
    return _loadOverviewData(
      api,
      settings.creditCardCycleDay,
      settings.salaryKeywordsList,
    );
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
          final SettingsProvider settings = context.read<SettingsProvider>();
          return ListView(
            padding: const EdgeInsets.all(8),
            children: <Widget>[
              _HeroCard(data: data),
              const SizedBox(height: 8),
              _StatChipsRow(
                data: data,
                cycleDay: settings.creditCardCycleDay,
              ),
              const SizedBox(height: 8),
              _IncomeCard(data: data),
              const SizedBox(height: 8),
              _CardCarousel(data: data),
              const SizedBox(height: 8),
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

/// Ordinal suffix for a day number (English: 1st, 2nd, 3rd, 4th…).
String _ordinal(int day) {
  if (day >= 11 && day <= 13) return '${day}th';
  switch (day % 10) {
    case 1:
      return '${day}st';
    case 2:
      return '${day}nd';
    case 3:
      return '${day}rd';
    default:
      return '${day}th';
  }
}

// ---------------------------------------------------------------------------
// Section 1: Hero "Total available" card
// ---------------------------------------------------------------------------

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.data});
  final _OverviewData data;

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final MoneyColors mc = Theme.of(context).extension<MoneyColors>()!;
    final Color fg = mc.heroForeground;

    if (data.bankAccounts.isEmpty) {
      return _buildShell(
        context: context,
        mc: mc,
        fg: fg,
        child: Padding(
          padding: const EdgeInsetsDirectional.all(16),
          child: Text(l10n.overviewNoData, style: TextStyle(color: fg)),
        ),
      );
    }

    // Group totals by currency.
    final Map<String, ({CurrencyRead currency, double sum})> totals =
        <String, ({CurrencyRead currency, double sum})>{};
    for (final AccountRead account in data.bankAccounts) {
      final double balance =
          double.tryParse(account.attributes.currentBalance ?? '0') ?? 0;
      final CurrencyRead currency = _currencyFromAccount(account);
      final String key = currency.attributes.code;
      totals[key] = (
        currency: currency,
        sum: (totals[key]?.sum ?? 0) + balance,
      );
    }

    // Primary total: first currency entry.
    final ({CurrencyRead currency, double sum}) primary = totals.values.first;

    return _buildShell(
      context: context,
      mc: mc,
      fg: fg,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 20, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Label
            Text(
              l10n.overviewHeroTotalAvailable,
              style: TextStyle(
                color: fg.withAlpha(0xB8), // ~72 % opacity
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 6),
            // Big total
            Text(
              primary.currency.fmt(primary.sum),
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                color: fg,
                fontWeight: FontWeight.w700,
                fontSize: 40,
                fontFeatures: const <FontFeature>[
                  FontFeature.tabularFigures(),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // Sub-line
            Text(
              l10n.overviewHeroAcrossAccounts(data.bankAccounts.length),
              style: TextStyle(
                color: fg.withAlpha(0xAA), // ~67 % opacity
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            // Per-bank row with vertical dividers
            _PerBankRow(
              accounts: data.bankAccounts,
              fg: fg,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShell({
    required BuildContext context,
    required MoneyColors mc,
    required Color fg,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsetsDirectional.fromSTEB(4, 4, 4, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: mc.heroGradient,
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        children: <Widget>[
          // Subtle radial sheen in top-end corner (glass effect).
          PositionedDirectional(
            top: -40,
            end: -40,
            child: Container(
              width: 160,
              height: 160,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[
                    fg.withAlpha(0x2E),
                    fg.withAlpha(0x00),
                  ],
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _PerBankRow extends StatelessWidget {
  const _PerBankRow({required this.accounts, required this.fg});
  final List<AccountRead> accounts;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final List<Widget> items = <Widget>[];
    for (int i = 0; i < accounts.length; i++) {
      if (i > 0) {
        items.add(
          Container(
            width: 1,
            height: 32,
            color: fg.withAlpha(0x40),
            margin: const EdgeInsetsDirectional.symmetric(horizontal: 10),
          ),
        );
      }
      items.add(_BankEntry(account: accounts[i], fg: fg));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: items,
      ),
    );
  }
}

class _BankEntry extends StatelessWidget {
  const _BankEntry({required this.account, required this.fg});
  final AccountRead account;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final CurrencyRead currency = _currencyFromAccount(account);
    final double balance =
        double.tryParse(account.attributes.currentBalance ?? '0') ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          account.attributes.name,
          style: TextStyle(
            color: fg.withAlpha(0xAA),
            fontSize: 11,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        const SizedBox(height: 2),
        Text(
          currency.fmt(balance),
          style: TextStyle(
            color: fg,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Section 2: Stat chips row (income this month · next charge)
// ---------------------------------------------------------------------------

class _StatChipsRow extends StatelessWidget {
  const _StatChipsRow({required this.data, required this.cycleDay});
  final _OverviewData data;
  final int cycleDay;

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final MoneyColors mc = Theme.of(context).extension<MoneyColors>()!;
    final ColorScheme cs = Theme.of(context).colorScheme;

    // This month's income: last entry in incomeMonths (oldest-first list).
    final double thisMonthIncome =
        data.incomeMonths.isNotEmpty ? data.incomeMonths.last.total : 0;

    // Sum upcoming charges across all cards.
    double totalCharge = 0;
    CurrencyRead? chargeCurrency;
    for (final _CardCharge cc in data.cardCharges) {
      totalCharge += cc.charge;
      chargeCurrency ??= _currencyFromAccount(cc.account);
    }

    // Default currency for income chips.
    final CurrencyRead incomeCurrency =
        data.bankAccounts.isNotEmpty
            ? _currencyFromAccount(data.bankAccounts.first)
            : context.read<FireflyService>().defaultCurrency;

    chargeCurrency ??= incomeCurrency;

    final String cycleLabel = _ordinal(cycleDay);

    return Row(
      children: <Widget>[
        Expanded(
          child: _StatChip(
            dotColor: mc.positive,
            label: l10n.overviewStatChipInThisMonth,
            valueText: '+${incomeCurrency.fmt(thisMonthIncome)}',
            valueColor: mc.positive,
            cs: cs,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatChip(
            dotColor: mc.negative,
            label: l10n.overviewStatChipNextCharge(cycleLabel),
            valueText: chargeCurrency.fmt(totalCharge),
            valueColor: mc.negative,
            cs: cs,
          ),
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.dotColor,
    required this.label,
    required this.valueText,
    required this.valueColor,
    required this.cs,
  });

  final Color dotColor;
  final String label;
  final String valueText;
  final Color valueColor;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outline, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            valueText,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w700,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section 3: Income line chart (salary vs. total income, last 6 months)
// ---------------------------------------------------------------------------

class _IncomeCard extends StatefulWidget {
  const _IncomeCard({required this.data});
  final _OverviewData data;

  @override
  State<_IncomeCard> createState() => _IncomeCardState();
}

class _IncomeCardState extends State<_IncomeCard> {
  late final TrackballBehavior _trackball = TrackballBehavior(
    enable: true,
    activationMode: ActivationMode.singleTap,
    tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
  );

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final MoneyColors mc = Theme.of(context).extension<MoneyColors>()!;
    final _OverviewData data = widget.data;

    if (data.incomeMonths.isEmpty) {
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

    return _overviewCard(
      context: context,
      title: l10n.overviewCardIncomeTitle,
      child: SizedBox(
        height: 260,
        child: SfCartesianChart(
          plotAreaBorderWidth: 0,
          margin: const EdgeInsets.fromLTRB(8, 8, 16, 0),
          trackballBehavior: _trackball,
          legend: Legend(
            isVisible: true,
            position: LegendPosition.bottom,
            overflowMode: LegendItemOverflowMode.wrap,
            itemPadding: 12,
            textStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.normal,
              color: cs.onSurfaceVariant,
            ),
          ),
          primaryXAxis: CategoryAxis(
            majorGridLines: const MajorGridLines(width: 0),
            axisLine: const AxisLine(width: 0),
            labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          primaryYAxis: NumericAxis(
            axisLine: const AxisLine(width: 0),
            majorTickLines: const MajorTickLines(size: 0),
            numberFormat: NumberFormat.compactCurrency(
              symbol: currency.attributes.symbol,
              decimalDigits: 0,
            ),
            labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          series: <CartesianSeries<_IncomeMonth, String>>[
            // Salary → gold (colorScheme.primary)
            LineSeries<_IncomeMonth, String>(
              name: l10n.incomeChartSalary,
              dataSource: data.incomeMonths,
              xValueMapper: (_IncomeMonth e, _) =>
                  DateFormat.MMM().format(e.month),
              yValueMapper: (_IncomeMonth e, _) => e.salary,
              color: cs.primary,
              width: 2.5,
              markerSettings: const MarkerSettings(isVisible: true),
            ),
            // Total income → emerald (mc.positive)
            LineSeries<_IncomeMonth, String>(
              name: l10n.incomeChartTotal,
              dataSource: data.incomeMonths,
              xValueMapper: (_IncomeMonth e, _) =>
                  DateFormat.MMM().format(e.month),
              yValueMapper: (_IncomeMonth e, _) => e.total,
              color: mc.positive,
              width: 2.5,
              markerSettings: const MarkerSettings(isVisible: true),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers (standard card shell reused by Income + Category cards)
// ---------------------------------------------------------------------------

/// Builds the standard card shell used by overview cards that keep the
/// plain surface style (income chart, upcoming-by-category).
Widget _overviewCard({
  required BuildContext context,
  required String title,
  required Widget child,
  VoidCallback? onTap,
}) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  return Container(
    margin: const EdgeInsetsDirectional.fromSTEB(4, 4, 4, 4),
    decoration: BoxDecoration(
      color: cs.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: cs.outline, width: 1),
    ),
    clipBehavior: Clip.hardEdge,
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

// ---------------------------------------------------------------------------
// Section 4: "Your cards" horizontal carousel
// ---------------------------------------------------------------------------

class _CardCarousel extends StatelessWidget {
  const _CardCarousel({required this.data});
  final _OverviewData data;

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final MoneyColors mc = Theme.of(context).extension<MoneyColors>()!;
    final ColorScheme cs = Theme.of(context).colorScheme;

    // Show ALL cards (including zero charge) in the carousel.
    final List<_CardCharge> cards = data.cardCharges;

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Section header
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 4, 8),
            child: Text(
              l10n.overviewCarouselSectionTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (cards.isEmpty)
            Container(
              padding: const EdgeInsetsDirectional.all(16),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: cs.outline, width: 1),
              ),
              child: Text(l10n.overviewNoData),
            )
          else
            SizedBox(
              height: 140,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 8, 0),
                itemCount: cards.length,
                separatorBuilder: (BuildContext context2, int index) =>
                    const SizedBox(width: 12),
                itemBuilder: (BuildContext ctx, int i) {
                  final _CardCharge cc = cards[i];
                  return _CardFace(
                    cardCharge: cc,
                    gradientColors: mc.cardGradients[i % mc.cardGradients.length],
                    heroGradient: mc.heroGradient,
                    faceFg: mc.cardFaceForeground,
                    goldDeep: mc.goldDeep,
                    l10n: l10n,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _CardFace extends StatelessWidget {
  const _CardFace({
    required this.cardCharge,
    required this.gradientColors,
    required this.heroGradient,
    required this.faceFg,
    required this.goldDeep,
    required this.l10n,
  });

  final _CardCharge cardCharge;
  final List<Color> gradientColors;
  final List<Color> heroGradient;
  final Color faceFg;
  final Color goldDeep;
  final S l10n;

  @override
  Widget build(BuildContext context) {
    final CurrencyRead currency = _currencyFromAccount(cardCharge.account);
    final String last4 = _cardLast4(cardCharge.account.attributes.name);
    final String name = cardCharge.account.attributes.name;

    return GestureDetector(
      onTap: () {
        // Navigate to card detail (same as Cards tab).
        final SettingsProvider settings = context.read<SettingsProvider>();
        final ({DateTime start, DateTime end}) cycle = currentCycle(
          DateTime.now(),
          settings.creditCardCycleDay,
        );
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder:
                (_) => CardDetailPage(
                  account: cardCharge.account,
                  prevCharge: cycle.start,
                  nextCharge: cycle.end,
                ),
          ),
        );
      },
      child: Container(
        width: 176,
        height: 112,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: AlignmentDirectional.topStart,
            end: AlignmentDirectional.bottomEnd,
            colors: gradientColors,
          ),
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          children: <Widget>[
            // Subtle radial sheen top-end corner.
            PositionedDirectional(
              top: -24,
              end: -24,
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: <Color>[
                      faceFg.withAlpha(0x24),
                      faceFg.withAlpha(0x00),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  // Gold chip rectangle
                  Container(
                    width: 26,
                    height: 19,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(5),
                      gradient: LinearGradient(
                        colors: heroGradient.length >= 2
                            ? <Color>[heroGradient[1], goldDeep]
                            : <Color>[goldDeep, goldDeep],
                      ),
                    ),
                  ),
                  // Card name + last4
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        name,
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
                  // Upcoming label + amount
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text(
                        l10n.overviewCarouselUpcoming,
                        style: TextStyle(
                          color: faceFg.withAlpha(0xAA), // ~66 %
                          fontSize: 10,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Text(
                        currency.fmt(cardCharge.charge),
                        style: TextStyle(
                          color: faceFg,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section 5: Upcoming charges by category (pie + bottom sheet drill-down)
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
    final ColorScheme cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
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
                    color: cs.outline,
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
                          color: Theme.of(context)
                              .extension<MoneyColors>()!
                              .negative,
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
    final ColorScheme cs = Theme.of(context).colorScheme;
    final MoneyColors mc = Theme.of(context).extension<MoneyColors>()!;

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

    // Build vault palette from theme tokens — distinct enough for pie slices.
    final List<Color> vaultPalette = <Color>[
      cs.primary,
      mc.positive,
      mc.negative,
      mc.goldDeep,
      cs.tertiary,
      cs.secondary,
      cs.primaryContainer,
      cs.tertiaryContainer,
      cs.secondaryContainer,
    ];

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
                      color: cs.onSurfaceVariant,
                    ),
              ),
              palette: vaultPalette,
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
                          color: cs.onSurfaceVariant,
                        ),
                    connectorLineSettings: ConnectorLineSettings(
                      color: cs.onSurfaceVariant,
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
            style: TextStyle(
              color: Theme.of(context).extension<MoneyColors>()!.negative,
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[
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
