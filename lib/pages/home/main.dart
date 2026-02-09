import 'dart:async';

import 'package:chopper/chopper.dart' show Response;
import 'package:collection/collection.dart';
import 'package:community_charts_flutter/community_charts_flutter.dart'
    as charts;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:timezone/timezone.dart';
import 'package:waterflyiii/animations.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/extensions.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';
import 'package:waterflyiii/pages/home.dart';
import 'package:waterflyiii/pages/home/main/charts/category.dart';
import 'package:waterflyiii/pages/home/main/charts/lastdays.dart';
import 'package:waterflyiii/pages/home/main/charts/netearnings.dart';
import 'package:waterflyiii/pages/home/main/charts/networth.dart';
import 'package:waterflyiii/pages/home/main/charts/summary.dart';
import 'package:waterflyiii/pages/home/main/dashboard.dart';
import 'package:waterflyiii/pages/home/main/dashboard_filter.dart';
import 'package:waterflyiii/settings.dart';
import 'package:waterflyiii/stock.dart';
import 'package:waterflyiii/timezonehandler.dart';
import 'package:waterflyiii/widgets/charts.dart';

/// One row for the "Charges per card" card: account label and total charges in period.
class _ChargePerCardRow {
  const _ChargePerCardRow({
    required this.label,
    required this.amount,
    required this.currency,
  });
  final String label;
  final double amount;
  final CurrencyRead currency;
}

class HomeMain extends StatefulWidget {
  const HomeMain({super.key});

  @override
  State<HomeMain> createState() => _HomeMainState();
}

class _HomeMainState extends State<HomeMain>
    with AutomaticKeepAliveClientMixin {
  final Logger log = Logger("Pages.Home.Main");

  final Map<DateTime, double> lastDaysExpense = <DateTime, double>{};
  final Map<DateTime, double> lastDaysIncome = <DateTime, double>{};
  final Map<DateTime, InsightTotalEntry> lastMonthsExpense =
      <DateTime, InsightTotalEntry>{};
  final Map<DateTime, InsightTotalEntry> lastMonthsIncome =
      <DateTime, InsightTotalEntry>{};
  Map<DateTime, double> lastMonthsEarned = <DateTime, double>{};
  Map<DateTime, double> lastMonthsSpent = <DateTime, double>{};
  Map<DateTime, double> lastMonthsAssets = <DateTime, double>{};
  Map<DateTime, double> lastMonthsLiabilities = <DateTime, double>{};
  List<ChartDataSet> overviewChartData = <ChartDataSet>[];
  final List<InsightGroupEntry> catChartData = <InsightGroupEntry>[];
  final List<InsightGroupEntry> tagChartData = <InsightGroupEntry>[];
  List<_ChargePerCardRow> chargesPerCardData = <_ChargePerCardRow>[];
  /// Labels hidden from the charges-per-card pie (toggled by tap).
  final Set<String> _chargesPerCardHiddenLabels = <String>{};
  final Map<String, BudgetProperties> budgetInfos =
      <String, BudgetProperties>{};
  late TransStock _stock;

  @override
  void initState() {
    super.initState();

    _stock = context.read<FireflyService>().transStock!;
    _stock.addListener(_refreshStats);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PageActions>().set(widget.key!, <Widget>[
        IconButton(
          icon: const Icon(Icons.filter_list),
          tooltip: S.of(context).homeMainFilterTitle,
          onPressed: () async {
            final bool? ok = await showDialog<bool>(
              context: context,
              builder: (BuildContext context) =>
                  const DashboardFilterDialog(),
            );
            if ((ok ?? false) && mounted) {
              unawaited(_refreshStats());
            }
          },
        ),
        IconButton(
          icon: const Icon(Icons.dashboard_customize_outlined),
          tooltip: S.of(context).homeMainDialogSettingsTitle,
          onPressed: () async {
            final bool? ok = await showDialog<bool>(
              context: context,
              builder: (BuildContext context) => const DashboardDialog(),
            );
            if (ok == null || !ok) {
              return;
            }
          },
        ),
      ]);
    });
  }

  @override
  void dispose() {
    _stock.removeListener(_refreshStats);

    super.dispose();
  }

  List<int>? _dashboardAccountIdsInt() {
    final List<String> ids =
        context.read<SettingsProvider>().dashboardAccountIds;
    if (ids.isEmpty) return null;
    final List<int> result =
        ids.map((String s) => int.tryParse(s)).whereType<int>().toList();
    return result.isEmpty ? null : result;
  }

  /// Parses a date from chart entry key (e.g. "2026-01-10" or "2026-01-10T00:00:00.000Z").
  /// Returns null if the key cannot be parsed.
  static DateTime? _parseEntryDate(String key) {
    final DateTime? d = DateTime.tryParse(key);
    return d;
  }

  /// Returns the balance value from a chart entry (API may return string or num).
  static double _entryValueToBalance(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  /// Returns true if [label] belongs to a selected account. The API may return
  /// the account name alone or in the form "Account Name (currency symbol)".
  static bool _isLabelForSelectedAccount(
    String label,
    Set<String> selectedNames,
  ) {
    if (selectedNames.contains(label)) return true;
    for (final String name in selectedNames) {
      if (label.startsWith('$name (')) return true;
    }
    return false;
  }

  Widget _buildAccountSummaryTable(List<ChartDataSet> data) {
    return Table(
      columnWidths: const <int, TableColumnWidth>{
        0: FixedColumnWidth(24),
        1: FlexColumnWidth(),
        2: IntrinsicColumnWidth(),
      },
      children: <TableRow>[
        TableRow(
          children: <Widget>[
            const SizedBox.shrink(),
            Text(
              S.of(context).generalAccount,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                S.of(context).generalBalance,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ],
        ),
        ...data.mapIndexed((int i, ChartDataSet e) {
          final Map<String, dynamic> entries =
              e.entries as Map<String, dynamic>;
          // Use chronologically last date in range (map iteration order may vary).
          double balance = 0;
          if (entries.isNotEmpty) {
            final MapEntry<String, dynamic> lastEntry = entries.entries
                .reduce(
                  (MapEntry<String, dynamic> a, MapEntry<String, dynamic> b) {
                    final DateTime? da = _parseEntryDate(a.key);
                    final DateTime? db = _parseEntryDate(b.key);
                    if (da == null) return b;
                    if (db == null) return a;
                    return da.isAfter(db) ? a : b;
                  },
                );
            balance = _entryValueToBalance(lastEntry.value);
          }
          final CurrencyRead currency = CurrencyRead(
            id: e.currencyId ?? "0",
            type: "currencies",
            attributes: CurrencyProperties(
              code: e.currencyCode ?? "",
              name: "",
              symbol: e.currencySymbol ?? "",
              decimalPlaces: e.currencyDecimalPlaces,
            ),
          );
          return TableRow(
            children: <Widget>[
              Align(
                alignment: Alignment.center,
                child: Text(
                  "⬤",
                  style: TextStyle(
                    color: charts.ColorUtil.toDartColor(
                      possibleChartColors[i % possibleChartColors.length],
                    ),
                    textBaseline: TextBaseline.ideographic,
                    height: 1.3,
                  ),
                ),
              ),
              Text(e.label!),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  currency.fmt(balance),
                  style: TextStyle(
                    color:
                        (balance < 0) ? Colors.red : Colors.green,
                    fontWeight: FontWeight.bold,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

  /// Key so the "Charges per card" card refetches when dashboard range changes.
  String _chargesPerCardKey() {
    final SettingsProvider s = context.read<SettingsProvider>();
    final (DateTime start, DateTime end) =
        s.getDashboardDateRange(
          context.read<FireflyService>().tzHandler.sNow().clearTime(),
        );
    return '${DateFormat('yyyy-MM-dd', 'en_US').format(start)}_'
        '${DateFormat('yyyy-MM-dd', 'en_US').format(end)}';
  }

  /// Fetches total charges (withdrawals + outbound transfers) per account for the dashboard date range.
  Future<bool> _fetchChargesPerCard() async {
    final FireflyIii api = context.read<FireflyService>().api;
    final TimeZoneHandler tzHandler = context.read<FireflyService>().tzHandler;
    final SettingsProvider settings = context.read<SettingsProvider>();
    final TransStock stock = context.read<FireflyService>().transStock!;

    final DateTime now = tzHandler.sNow().clearTime();
    final (DateTime start, DateTime end) =
        settings.getDashboardDateRange(now);
    final String startStr = DateFormat('yyyy-MM-dd', 'en_US').format(start);
    final String endStr = DateFormat('yyyy-MM-dd', 'en_US').format(end);

    final (
      Response<AccountArray> respAssets,
      Response<AccountArray> respLiabilities,
    ) = await (
      api.v1AccountsGet(type: AccountTypeFilter.asset),
      api.v1AccountsGet(type: AccountTypeFilter.liabilities),
    ).wait;
    if (!mounted) return false;
    apiThrowErrorIfEmpty(respAssets, context);
    apiThrowErrorIfEmpty(respLiabilities, context);

    final List<AccountRead> accounts = <AccountRead>[
      ...?respAssets.body?.data,
      ...?respLiabilities.body?.data,
    ];

    final List<_ChargePerCardRow> rows = <_ChargePerCardRow>[];
    for (final AccountRead account in accounts) {
      double totalCharges = 0;
      int page = 1;
      const int limit = 250;
      List<TransactionRead> txList;
      do {
        txList = await stock.getAccount(
          id: account.id,
          page: page,
          limit: limit,
          start: startStr,
          end: endStr,
          type: TransactionTypeFilter.all,
        );
        if (!mounted) return false;
        for (final TransactionRead tx in txList) {
          for (final TransactionSplit split in tx.attributes.transactions) {
            if (split.sourceId != account.id) continue;
            final double amount = double.tryParse(split.amount) ?? 0;
            if (split.type == TransactionTypeProperty.withdrawal) {
              totalCharges += amount;
            } else if (split.type == TransactionTypeProperty.transfer) {
              totalCharges += amount;
            }
          }
        }
        page++;
      } while (txList.length >= limit);

      if (totalCharges > 0) {
        final AccountProperties att = account.attributes;
        final CurrencyRead currency = CurrencyRead(
          id: att.currencyId ?? '0',
          type: 'currencies',
          attributes: CurrencyProperties(
            code: att.currencyCode ?? '',
            name: att.currencyName ?? '',
            symbol: att.currencySymbol ?? '',
            decimalPlaces: att.currencyDecimalPlaces,
          ),
        );
        final String label = _cardLabelFromAccountName(att.name);
        rows.add(_ChargePerCardRow(
          label: label,
          amount: totalCharges,
          currency: currency,
        ));
      }
    }

    rows.sort((_ChargePerCardRow a, _ChargePerCardRow b) =>
        b.amount.compareTo(a.amount));
    if (mounted) {
      chargesPerCardData = rows;
      _chargesPerCardHiddenLabels.clear();
    }
    return true;
  }

  /// Prefer last 4 digits if name ends with 4 digits (e.g. "Card 7725" -> "7725"), else full name.
  static String _cardLabelFromAccountName(String name) {
    if (name.length >= 4) {
      final String last4 = name.substring(name.length - 4);
      if (RegExp(r'^\d{4}$').hasMatch(last4)) return last4;
    }
    return name;
  }

  Widget _buildChargesPerCardContent() {
    if (chargesPerCardData.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          S.of(context).homeMainChartChargesPerCardEmpty,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    // Pie chart data (one slice per card; amounts may be in different currencies).
    final List<LabelAmountChart> pieData = chargesPerCardData
        .map((_ChargePerCardRow r) => LabelAmountChart(r.label, r.amount))
        .toList();

    // Visible slices: exclude hidden (tapped-away). If all hidden, show full pie and reset.
    List<LabelAmountChart> pieDataVisible = pieData
        .where((LabelAmountChart d) => !_chargesPerCardHiddenLabels.contains(d.label))
        .toList();
    if (pieDataVisible.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _chargesPerCardHiddenLabels.clear());
      });
      pieDataVisible = List<LabelAmountChart>.from(pieData);
    }

    // Totals per currency.
    final Map<String, ({CurrencyRead currency, double sum})> totalsByCurrency =
        <String, ({CurrencyRead currency, double sum})>{};
    for (final _ChargePerCardRow row in chargesPerCardData) {
      final String key = row.currency.id;
      if (totalsByCurrency.containsKey(key)) {
        final ({CurrencyRead currency, double sum}) t = totalsByCurrency[key]!;
        totalsByCurrency[key] = (currency: t.currency, sum: t.sum + row.amount);
      } else {
        totalsByCurrency[key] = (currency: row.currency, sum: row.amount);
      }
    }
    final List<({CurrencyRead currency, double sum})> totals =
        totalsByCurrency.values.toList();

    return Column(
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
              textStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.normal,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            palette: possibleChartColorsDart,
            series: <CircularSeries<LabelAmountChart, String>>[
              PieSeries<LabelAmountChart, String>(
                dataSource: pieDataVisible,
                xValueMapper: (LabelAmountChart d, _) => d.label,
                yValueMapper: (LabelAmountChart d, _) => d.amount,
                dataLabelMapper: (LabelAmountChart d, _) => d.label,
                dataLabelSettings: DataLabelSettings(
                  isVisible: true,
                  labelPosition: ChartDataLabelPosition.outside,
                  textStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.normal,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  connectorLineSettings: ConnectorLineSettings(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                onPointTap: (ChartPointDetails details) {
                  if (details.pointIndex == null ||
                      details.dataPoints == null ||
                      details.pointIndex! >= pieDataVisible.length) {
                    return;
                  }
                  final String tappedLabel = pieDataVisible[details.pointIndex!].label;
                  setState(() {
                    if (_chargesPerCardHiddenLabels.contains(tappedLabel)) {
                      _chargesPerCardHiddenLabels.remove(tappedLabel);
                    } else {
                      _chargesPerCardHiddenLabels.add(tappedLabel);
                    }
                  });
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Table(
            columnWidths: const <int, TableColumnWidth>{
              0: IntrinsicColumnWidth(),
              1: IntrinsicColumnWidth(),
            },
            children: <TableRow>[
              ...chargesPerCardData.map((_ChargePerCardRow row) => TableRow(
                children: <Widget>[
                  Text(row.label),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      row.currency.fmt(row.amount),
                      style: TextStyle(
                        color: Colors.red.shade700,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                ],
              )),
              TableRow(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      S.of(context).homeMainChartChargesPerCardTotal,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: totals.length == 1
                          ? Text(
                              totals.first.currency.fmt(totals.first.sum),
                              style: TextStyle(
                                color: Colors.red.shade800,
                                fontWeight: FontWeight.bold,
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              mainAxisSize: MainAxisSize.min,
                              children: totals
                                  .map(
                                    (({CurrencyRead currency, double sum}) t) =>
                                        Text(
                                      t.currency.fmt(t.sum),
                                      style: TextStyle(
                                        color: Colors.red.shade800,
                                        fontWeight: FontWeight.bold,
                                        fontFeatures: const <FontFeature>[
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<bool> _fetchLastDays() async {
    if (lastDaysExpense.isNotEmpty && lastDaysIncome.isNotEmpty) {
      return true;
    }

    final FireflyIii api = context.read<FireflyService>().api;
    final TimeZoneHandler tzHandler = context.read<FireflyService>().tzHandler;
    final SettingsProvider settings = context.read<SettingsProvider>();

    // Use noon due to daylight saving time
    final TZDateTime nowTz = tzHandler.sNow().setTimeOfDay(
      const TimeOfDay(hour: 12, minute: 0),
    );
    final DateTime now = nowTz.toLocal();
    final (DateTime start, DateTime end) =
        settings.getDashboardDateRange(now);
    final String startStr = DateFormat('yyyy-MM-dd', 'en_US').format(start);
    final String endStr = DateFormat('yyyy-MM-dd', 'en_US').format(end);

    final Response<List<ChartDataSet>> respBalanceData = await api
        .v1ChartBalanceBalanceGet(
          start: startStr,
          end: endStr,
          period: V1ChartBalanceBalanceGetPeriod.value_1d,
          accounts: _dashboardAccountIdsInt(),
        );
    apiThrowErrorIfEmpty(respBalanceData, mounted ? context : null);

    for (ChartDataSet e in respBalanceData.body!) {
      final Map<String, dynamic> entries = e.entries as Map<String, dynamic>;
      entries.forEach((String dateStr, dynamic valueStr) {
        final DateTime date = tzHandler
            .sTime(DateTime.parse(dateStr))
            .toLocal()
            .setTimeOfDay(const TimeOfDay(hour: 12, minute: 0));

        final double value = double.tryParse(valueStr) ?? 0;
        if (e.label == "earned") {
          lastDaysIncome[date] = (lastDaysIncome[date] ?? 0) + value;
        } else if (e.label == "spent") {
          lastDaysExpense[date] = (lastDaysExpense[date] ?? 0) + value;
        }
      });
    }

    return true;
  }

  Future<bool> _fetchOverviewChart() async {
    if (overviewChartData.isNotEmpty) {
      return true;
    }

    final FireflyIii api = context.read<FireflyService>().api;
    final TimeZoneHandler tzHandler = context.read<FireflyService>().tzHandler;
    final SettingsProvider settings = context.read<SettingsProvider>();

    final DateTime now = tzHandler.sNow().clearTime();
    final (DateTime start, DateTime end) =
        settings.getDashboardDateRange(now);
    final String startStr = DateFormat('yyyy-MM-dd', 'en_US').format(start);
    final String endStr = DateFormat('yyyy-MM-dd', 'en_US').format(end);

    final Response<ChartLine> respChartData = await api
        .v1ChartAccountOverviewGet(
          start: startStr,
          end: endStr,
          period: V1ChartAccountOverviewGetPeriod.value_1d,
        );
    apiThrowErrorIfEmpty(respChartData, mounted ? context : null);

    List<ChartDataSet> overview = respChartData.body!;

    // Restrict to dashboard date range (same as Accounts in range card).
    final DateTime startDate = DateTime(start.year, start.month, start.day);
    final DateTime endDate = DateTime(end.year, end.month, end.day);
    final List<ChartDataSet> overviewInRange = <ChartDataSet>[];
    for (final ChartDataSet e in overview) {
      final Object? entriesRaw = e.entries;
      if (entriesRaw == null) continue;
      final Map<String, dynamic> raw =
          Map<String, dynamic>.from(entriesRaw as Map<String, dynamic>);
      final List<MapEntry<String, dynamic>> inRange = raw.entries
          .where((MapEntry<String, dynamic> entry) {
            final DateTime? d = _parseEntryDate(entry.key);
            if (d == null) return false;
            final DateTime dDate = DateTime(d.year, d.month, d.day);
            return !dDate.isBefore(startDate) && !dDate.isAfter(endDate);
          })
          .toList()
        ..sort(
          (MapEntry<String, dynamic> a, MapEntry<String, dynamic> b) {
            final DateTime? da = _parseEntryDate(a.key);
            final DateTime? db = _parseEntryDate(b.key);
            if (da == null && db == null) return 0;
            if (da == null) return 1;
            if (db == null) return -1;
            return da.compareTo(db);
          },
        );
      final Map<String, dynamic> filtered =
          Map<String, dynamic>.fromEntries(inRange);
      if (filtered.isNotEmpty) {
        overviewInRange.add(e.copyWith(entries: filtered));
      }
    }
    overviewChartData = overviewInRange.isNotEmpty ? overviewInRange : overview;

    // When dashboard filter has selected accounts, restrict Account Summary to those only
    final List<String> selectedIds = settings.dashboardAccountIds;
    if (selectedIds.isNotEmpty) {
      final (
        Response<AccountArray> respAssets,
        Response<AccountArray> respLiabilities,
      ) = await (
            api.v1AccountsGet(type: AccountTypeFilter.asset),
            api.v1AccountsGet(type: AccountTypeFilter.liabilities),
          ).wait;
      if (mounted) {
        apiThrowErrorIfEmpty(respAssets, context);
        apiThrowErrorIfEmpty(respLiabilities, context);
      }
      final Set<String> selectedNames = <String>{};
      final List<AccountRead> allAccounts = <AccountRead>[
        ...?respAssets.body?.data,
        ...?respLiabilities.body?.data,
      ];
      for (final AccountRead acc in allAccounts) {
        if (selectedIds.contains(acc.id)) {
          selectedNames.add(acc.attributes.name);
        }
      }
      if (mounted && selectedNames.isNotEmpty) {
        overviewChartData = overviewChartData
            .where((ChartDataSet e) =>
                e.label != null &&
                _isLabelForSelectedAccount(e.label!, selectedNames))
            .toList();
      }
    }

    return true;
  }

  Future<bool> _fetchLastMonths() async {
    if (lastMonthsExpense.isNotEmpty && lastMonthsIncome.isNotEmpty) {
      return true;
    }

    final FireflyIii api = context.read<FireflyService>().api;
    final TimeZoneHandler tzHandler = context.read<FireflyService>().tzHandler;
    final SettingsProvider settings = context.read<SettingsProvider>();

    final DateTime now = tzHandler.sNow().clearTime();
    final (DateTime rangeStart, DateTime rangeEnd) =
        settings.getDashboardDateRange(now);
    final List<DateTime> lastMonths = <DateTime>[];
    for (int i = 0; i < 12; i++) {
      final DateTime monthStart = DateTime(rangeEnd.year, rangeEnd.month - i, 1);
      if (monthStart.isBefore(rangeStart)) break;
      lastMonths.add(monthStart);
    }
    if (lastMonths.isEmpty) {
      lastMonths.add(DateTime(rangeEnd.year, rangeEnd.month, 1));
    }

    final List<int>? accountIds = _dashboardAccountIdsInt();

    for (DateTime e in lastMonths) {
      late DateTime start;
      late DateTime end;
      final DateTime monthEnd = e.copyWith(month: e.month + 1, day: 0);
      if (e == lastMonths.first) {
        start = e;
        end = rangeEnd.isBefore(monthEnd) ? rangeEnd : monthEnd;
      } else {
        start = e;
        end = monthEnd;
      }
      final (
        Response<InsightTotal> respInsightExpense,
        Response<InsightTotal> respInsightIncome,
      ) = await (
            api.v1InsightExpenseTotalGet(
              start: DateFormat('yyyy-MM-dd', 'en_US').format(start),
              end: DateFormat('yyyy-MM-dd', 'en_US').format(end),
              accounts: accountIds,
            ),
            api.v1InsightIncomeTotalGet(
              start: DateFormat('yyyy-MM-dd', 'en_US').format(start),
              end: DateFormat('yyyy-MM-dd', 'en_US').format(end),
              accounts: accountIds,
            ),
          ).wait;
      apiThrowErrorIfEmpty(respInsightExpense, mounted ? context : null);
      apiThrowErrorIfEmpty(respInsightIncome, mounted ? context : null);

      lastMonthsExpense[e] =
          respInsightExpense.body!.isNotEmpty
              ? respInsightExpense.body!.first
              : const InsightTotalEntry(differenceFloat: 0);
      lastMonthsIncome[e] =
          respInsightIncome.body!.isNotEmpty
              ? respInsightIncome.body!.first
              : const InsightTotalEntry(differenceFloat: 0);
    }

    // If too big digits are present (>=100000), only show two columns to avoid
    // wrapping issues. See #30.
    double maxNum = 0;
    lastMonthsIncome.forEach((_, InsightTotalEntry value) {
      if ((value.differenceFloat ?? 0) > maxNum) {
        maxNum = value.differenceFloat ?? 0;
      }
    });
    lastMonthsExpense.forEach((_, InsightTotalEntry value) {
      if ((value.differenceFloat ?? 0) > maxNum) {
        maxNum = value.differenceFloat ?? 0;
      }
    });
    if (maxNum >= 100000) {
      lastMonthsIncome.remove(lastMonthsIncome.keys.first);
      lastMonthsExpense.remove(lastMonthsExpense.keys.first);
    }

    return true;
  }

  Future<bool> _fetchCategories({bool tags = false}) async {
    if ((tags && tagChartData.isNotEmpty) ||
        (!tags && catChartData.isNotEmpty)) {
      return true;
    }

    final FireflyIii api = context.read<FireflyService>().api;
    final TimeZoneHandler tzHandler = context.read<FireflyService>().tzHandler;
    final CurrencyRead defaultCurrency =
        context.read<FireflyService>().defaultCurrency;
    final SettingsProvider settings = context.read<SettingsProvider>();

    final DateTime now = tzHandler.sNow().clearTime();
    final (DateTime start, DateTime end) =
        settings.getDashboardDateRange(now);
    final String startStr = DateFormat('yyyy-MM-dd', 'en_US').format(start);
    final String endStr = DateFormat('yyyy-MM-dd', 'en_US').format(end);
    final List<int>? accountIds = _dashboardAccountIdsInt();

    late final Response<InsightGroup> respIncomeData;
    late final Response<InsightGroup> respExpenseData;
    if (!tags) {
      (respIncomeData, respExpenseData) =
          await (
            api.v1InsightIncomeCategoryGet(
              start: startStr,
              end: endStr,
              accounts: accountIds,
            ),
            api.v1InsightExpenseCategoryGet(
              start: startStr,
              end: endStr,
              accounts: accountIds,
            ),
          ).wait;
    } else {
      (respIncomeData, respExpenseData) =
          await (
            api.v1InsightIncomeTagGet(
              start: startStr,
              end: endStr,
              accounts: accountIds,
            ),
            api.v1InsightExpenseTagGet(
              start: startStr,
              end: endStr,
              accounts: accountIds,
            ),
          ).wait;
    }
    apiThrowErrorIfEmpty(respIncomeData, mounted ? context : null);
    apiThrowErrorIfEmpty(respExpenseData, mounted ? context : null);

    final Map<String, double> incomes = <String, double>{};
    for (InsightGroupEntry entry
        in respIncomeData.body ?? <InsightGroupEntry>[]) {
      if (entry.id?.isEmpty ?? true) {
        continue;
      }
      if (entry.currencyId == null || entry.currencyId != defaultCurrency.id) {
        continue;
      }
      incomes[entry.id!] = entry.differenceFloat ?? 0;
    }

    for (InsightGroupEntry entry in respExpenseData.body!) {
      if (entry.id?.isEmpty ?? true) {
        continue;
      }
      if (entry.currencyId == null || entry.currencyId != defaultCurrency.id) {
        continue;
      }
      double amount = entry.differenceFloat ?? 0;
      if (incomes.containsKey(entry.id)) {
        amount += incomes[entry.id]!;
      }
      // Don't add "positive" entries, we want to show expenses
      if (amount >= 0) {
        continue;
      }
      tags
          ? tagChartData.add(entry.copyWith(differenceFloat: amount))
          : catChartData.add(entry.copyWith(differenceFloat: amount));
    }

    return true;
  }

  Future<List<BudgetLimitRead>> _fetchBudgets() async {
    final FireflyIii api = context.read<FireflyService>().api;
    final TimeZoneHandler tzHandler = context.read<FireflyService>().tzHandler;
    final SettingsProvider settings = context.read<SettingsProvider>();

    final DateTime now = tzHandler.sNow().clearTime();
    final (DateTime start, DateTime end) =
        settings.getDashboardDateRange(now);
    final String startStr = DateFormat('yyyy-MM-dd', 'en_US').format(start);
    final String endStr = DateFormat('yyyy-MM-dd', 'en_US').format(end);

    final (
      Response<BudgetArray> respBudgetInfos,
      Response<BudgetLimitArray> respBudgets,
    ) = await (
          api.v1BudgetsGet(),
          api.v1BudgetLimitsGet(
            start: startStr,
            end: endStr,
          ),
        ).wait;
    apiThrowErrorIfEmpty(respBudgetInfos, mounted ? context : null);
    apiThrowErrorIfEmpty(respBudgets, mounted ? context : null);

    for (BudgetRead budget in respBudgetInfos.body!.data) {
      budgetInfos[budget.id] = budget.attributes;
    }

    respBudgets.body!.data.sort((BudgetLimitRead a, BudgetLimitRead b) {
      final BudgetProperties? budgetA = budgetInfos[a.attributes.budgetId];
      final BudgetProperties? budgetB = budgetInfos[b.attributes.budgetId];

      if (budgetA == null && budgetB != null) {
        return -1;
      } else if (budgetA != null && budgetB == null) {
        return 1;
      } else if (budgetA == null && budgetB == null) {
        return 0;
      }
      final int compare = (budgetA!.order ?? -1).compareTo(
        budgetB!.order ?? -1,
      );
      if (compare != 0) {
        return compare;
      }
      return a.attributes.start!.compareTo(b.attributes.start!);
    });

    return respBudgets.body!.data;
  }

  Future<List<BillRead>> _fetchBills() async {
    final FireflyIii api = context.read<FireflyService>().api;
    final TimeZoneHandler tzHandler = context.read<FireflyService>().tzHandler;
    final SettingsProvider settings = context.read<SettingsProvider>();

    final DateTime now = tzHandler.sNow().clearTime();
    final (DateTime _, DateTime rangeEnd) =
        settings.getDashboardDateRange(now);
    final DateTime end = rangeEnd.copyWith(day: rangeEnd.day + 7);

    final Response<BillArray> respBills = await api.v1BillsGet(
      start: DateFormat('yyyy-MM-dd', 'en_US').format(rangeEnd),
      end: DateFormat('yyyy-MM-dd', 'en_US').format(end),
    );
    apiThrowErrorIfEmpty(respBills, mounted ? context : null);

    return respBills.body!.data
        .where(
          (BillRead e) => (e.attributes.nextExpectedMatch != null
                  ? tzHandler.sTime(e.attributes.nextExpectedMatch!)
                  : end.copyWith(day: end.day + 2))
              .toLocal()
              .clearTime()
              .isBefore(end.copyWith(day: end.day + 1)),
        )
        .toList(growable: false);
  }

  Future<bool> _fetchBalance() async {
    if (lastMonthsEarned.isNotEmpty) {
      return true;
    }

    final FireflyIii api = context.read<FireflyService>().api;
    final TimeZoneHandler tzHandler = context.read<FireflyService>().tzHandler;
    final SettingsProvider settings = context.read<SettingsProvider>();

    final DateTime now = tzHandler.sNow().clearTime();
    final (DateTime start, DateTime end) =
        settings.getDashboardDateRange(now);
    final String startStr = DateFormat('yyyy-MM-dd', 'en_US').format(start);
    final String endStr = DateFormat('yyyy-MM-dd', 'en_US').format(end);

    final (
      Response<AccountArray> respAssetAccounts,
      Response<AccountArray> respLiabilityAccounts,
      Response<List<ChartDataSet>> respBalanceData,
    ) = await (
          api.v1AccountsGet(type: AccountTypeFilter.asset),
          api.v1AccountsGet(type: AccountTypeFilter.liabilities),
          api.v1ChartAccountOverviewGet(
            start: startStr,
            end: endStr,
            preselected: V1ChartAccountOverviewGetPreselected.all,
            period: V1ChartAccountOverviewGetPeriod.value_1d,
          ),
        ).wait;
    apiThrowErrorIfEmpty(respAssetAccounts, mounted ? context : null);
    apiThrowErrorIfEmpty(respLiabilityAccounts, mounted ? context : null);
    apiThrowErrorIfEmpty(respBalanceData, mounted ? context : null);

    final Map<String, bool> includeInNetWorth = <String, bool>{
      for (AccountRead e in respAssetAccounts.body!.data)
        e.attributes.name: e.attributes.includeNetWorth ?? true,
    };
    includeInNetWorth.addAll(<String, bool>{
      for (AccountRead e in respLiabilityAccounts.body!.data)
        e.attributes.name: e.attributes.includeNetWorth ?? true,
    });
    for (ChartDataSet e in respBalanceData.body!) {
      if (includeInNetWorth.containsKey(e.label) &&
          includeInNetWorth[e.label] != true) {
        continue;
      }
      final Map<String, dynamic> entries = e.entries as Map<String, dynamic>;
      entries.forEach((String dateStr, dynamic valueStr) {
        DateTime date = tzHandler.sTime(DateTime.parse(dateStr)).toLocal();
        if (
        // Range end month: take end day
        (date.month == end.month &&
                date.year == end.year &&
                date.day == end.day) ||
            // Other month: take last day of month
            (date.month != end.month &&
                date.copyWith(day: date.day + 1).month != date.month)) {
          final double value = double.tryParse(valueStr) ?? 0;
          // We don't really care about the exact date. Always using the first
          // ensures the loops below to fill up gaps work properly.
          date = date.copyWith(day: 1);
          if (value > 0) {
            lastMonthsAssets[date] = (lastMonthsAssets[date] ?? 0) + value;
          }
          if (value < 0) {
            lastMonthsLiabilities[date] =
                (lastMonthsLiabilities[date] ?? 0) + value;
          }
        }
      });
    }

    if (lastMonthsEarned.length < 3) {
      final DateTime lastDate = end.copyWith(day: 1);
      for (int i = 0; i < 3; i++) {
        final DateTime newDate = lastDate.copyWith(month: lastDate.month - i);
        lastMonthsEarned[newDate] = lastMonthsEarned[newDate] ?? 0;
      }
    }
    lastMonthsEarned = Map<DateTime, double>.fromEntries(
      lastMonthsEarned.entries.toList()
        ..sortBy((MapEntry<DateTime, double> e) => e.key),
    );

    if (lastMonthsSpent.length < 3) {
      final DateTime lastDate = end.copyWith(day: 1);
      for (int i = 0; i < 3; i++) {
        final DateTime newDate = lastDate.copyWith(month: lastDate.month - i);
        lastMonthsSpent[newDate] = lastMonthsSpent[newDate] ?? 0;
      }
    }
    lastMonthsSpent = Map<DateTime, double>.fromEntries(
      lastMonthsSpent.entries.toList()
        ..sortBy((MapEntry<DateTime, double> e) => e.key),
    );

    if (lastMonthsAssets.length < 12) {
      final DateTime lastDate = end.copyWith(day: 1);
      for (int i = 0; i < 12; i++) {
        final DateTime newDate = lastDate.copyWith(month: lastDate.month - i);
        lastMonthsAssets[newDate] = lastMonthsAssets[newDate] ?? 0;
      }
    }
    lastMonthsAssets = Map<DateTime, double>.fromEntries(
      lastMonthsAssets.entries.toList()
        ..sortBy((MapEntry<DateTime, double> e) => e.key),
    );

    if (lastMonthsLiabilities.length < 12) {
      final DateTime lastDate = end.copyWith(day: 1);
      for (int i = 0; i < 12; i++) {
        final DateTime newDate = lastDate.copyWith(month: lastDate.month - i);
        lastMonthsLiabilities[newDate] = lastMonthsLiabilities[newDate] ?? 0;
      }
    }
    lastMonthsLiabilities = Map<DateTime, double>.fromEntries(
      lastMonthsLiabilities.entries.toList()
        ..sortBy((MapEntry<DateTime, double> e) => e.key),
    );

    return true;
  }

  Future<void> _refreshStats() async {
    setState(() {
      lastDaysExpense.clear();
      lastDaysIncome.clear();
      overviewChartData.clear();
      lastMonthsExpense.clear();
      lastMonthsIncome.clear();
      tagChartData.clear();
      catChartData.clear();
      lastMonthsEarned.clear();
      lastMonthsSpent.clear();
      lastMonthsAssets.clear();
      lastMonthsLiabilities.clear();
      chargesPerCardData = <_ChargePerCardRow>[];
      _chargesPerCardHiddenLabels.clear();
    });
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    log.finest(() => "build()");

    final CurrencyRead defaultCurrency =
        context.read<FireflyService>().defaultCurrency;

    final List<DashboardCards> cards = List<DashboardCards>.from(
      context.watch<SettingsProvider>().dashboardOrder,
    );

    final List<DashboardCards> hidden =
        context.watch<SettingsProvider>().dashboardHidden;
    for (DashboardCards e in hidden) {
      cards.remove(e);
    }

    return RefreshIndicator(
      onRefresh: _refreshStats,
      child: ListView(
        cacheExtent: 1000,
        padding: const EdgeInsets.all(8),
        children: <Widget>[
          for (int i = 0; i < cards.length; i++)
            switch (cards[i]) {
              DashboardCards.dailyavg => ChartCard(
                title: S.of(context).homeMainChartDailyTitle,
                future: _fetchLastDays(),
                summary: () {
                  double sevenDayTotal = 0;
                  lastDaysExpense.forEach(
                    (DateTime _, double e) => sevenDayTotal -= e.abs(),
                  );
                  lastDaysIncome.forEach(
                    (DateTime _, double e) => sevenDayTotal += e.abs(),
                  );
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(S.of(context).homeMainChartDailyAvg),
                      Text(
                        defaultCurrency.fmt(sevenDayTotal / 7),
                        style: TextStyle(
                          color: sevenDayTotal < 0 ? Colors.red : Colors.green,
                          fontWeight: FontWeight.bold,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  );
                },
                height: 125,
                child:
                    () => LastDaysChart(
                      expenses: lastDaysExpense,
                      incomes: lastDaysIncome,
                    ),
              ),
              DashboardCards.categories => ChartCard(
                title: S.of(context).homeMainChartCategoriesTitle,
                future: _fetchCategories(),
                height: 175,
                child: () => CategoryChart(data: catChartData),
              ),
              DashboardCards.tags => ChartCard(
                title: S.of(context).homeMainChartTagsTitle,
                future: _fetchCategories(tags: true),
                height: 175,
                child: () => CategoryChart(data: tagChartData),
              ),
              DashboardCards.accounts => ChartCard(
                title: S.of(context).homeMainChartAccountsTitle,
                future: _fetchOverviewChart(),
                summary: () => _buildAccountSummaryTable(overviewChartData),
                height: 175,
                onTap:
                    () => showDialog<void>(
                      context: context,
                      builder:
                          (BuildContext context) => const SummaryChartPopup(),
                    ),
                child: () => SummaryChart(data: overviewChartData),
              ),
              DashboardCards.chargesPerCard => ChartCard(
                key: ValueKey<String>(_chargesPerCardKey()),
                title: S.of(context).homeMainChartChargesPerCardTitle,
                future: _fetchChargesPerCard(),
                height: 420,
                child: () => _buildChargesPerCardContent(),
              ),
              DashboardCards.netearnings => ChartCard(
                title: S.of(context).homeMainChartNetEarningsTitle,
                future: _fetchLastMonths(),
                summary:
                    () => Table(
                      // border: TableBorder.all(), // :DEBUG:
                      columnWidths: const <int, TableColumnWidth>{
                        0: FixedColumnWidth(24),
                        1: IntrinsicColumnWidth(),
                        2: FlexColumnWidth(),
                        3: FlexColumnWidth(),
                        4: FlexColumnWidth(),
                      },
                      children: <TableRow>[
                        TableRow(
                          children: <Widget>[
                            const SizedBox.shrink(),
                            const SizedBox.shrink(),
                            ...lastMonthsIncome.keys.toList().reversed.map(
                              (DateTime e) => Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  DateFormat(DateFormat.MONTH).format(e),
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                              ),
                            ),
                          ],
                        ),
                        TableRow(
                          children: <Widget>[
                            const Align(
                              alignment: Alignment.center,
                              child: Text(
                                "⬤",
                                style: TextStyle(
                                  color: Colors.green,
                                  textBaseline: TextBaseline.ideographic,
                                  height: 1.3,
                                ),
                              ),
                            ),
                            Text(S.of(context).generalIncome),
                            ...lastMonthsIncome.entries.toList().reversed.map(
                              (MapEntry<DateTime, InsightTotalEntry> e) =>
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      defaultCurrency.fmt(
                                        e.value.differenceFloat ?? 0,
                                      ),
                                      style: const TextStyle(
                                        fontFeatures: <FontFeature>[
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ),
                            ),
                          ],
                        ),
                        TableRow(
                          children: <Widget>[
                            const Align(
                              alignment: Alignment.center,
                              child: Text(
                                "⬤",
                                style: TextStyle(
                                  color: Colors.red,
                                  textBaseline: TextBaseline.ideographic,
                                  height: 1.3,
                                ),
                              ),
                            ),
                            Text(S.of(context).generalExpenses),
                            ...lastMonthsExpense.entries.toList().reversed.map(
                              (MapEntry<DateTime, InsightTotalEntry> e) =>
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      defaultCurrency.fmt(
                                        e.value.differenceFloat ?? 0,
                                      ),
                                      style: const TextStyle(
                                        fontFeatures: <FontFeature>[
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ),
                            ),
                          ],
                        ),
                        TableRow(
                          children: <Widget>[
                            const SizedBox.shrink(),
                            Text(
                              S.of(context).generalSum,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            ...lastMonthsIncome.entries.toList().reversed.map((
                              MapEntry<DateTime, InsightTotalEntry> e,
                            ) {
                              final double income =
                                  e.value.differenceFloat ?? 0;
                              double expense = 0;
                              if (lastMonthsExpense.containsKey(e.key)) {
                                expense =
                                    lastMonthsExpense[e.key]!.differenceFloat ??
                                    0;
                              }
                              final double sum = income + expense;
                              return Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  defaultCurrency.fmt(sum),
                                  style: TextStyle(
                                    color:
                                        (sum < 0) ? Colors.red : Colors.green,
                                    fontWeight: FontWeight.bold,
                                    fontFeatures: const <FontFeature>[
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              );
                            }),
                          ],
                        ),
                      ],
                    ),
                onTap:
                    () => showDialog<void>(
                      context: context,
                      builder:
                          (BuildContext context) =>
                              const NetEarningsChartPopup(),
                    ),
                child:
                    () => NetEarningsChart(
                      expenses: lastMonthsExpense,
                      income: lastMonthsIncome,
                    ),
              ),
              DashboardCards.networth => ChartCard(
                title: S.of(context).homeMainChartNetWorthTitle,
                future: _fetchBalance(),
                summary:
                    () => Table(
                      //border: TableBorder.all(), // :DEBUG:
                      columnWidths: const <int, TableColumnWidth>{
                        0: FixedColumnWidth(24),
                        1: IntrinsicColumnWidth(),
                        2: FlexColumnWidth(),
                        3: FlexColumnWidth(),
                        4: FlexColumnWidth(),
                      },
                      children: <TableRow>[
                        TableRow(
                          children: <Widget>[
                            const SizedBox.shrink(),
                            const SizedBox.shrink(),
                            ...lastMonthsAssets.keys
                                .toList()
                                .reversed
                                .take(3)
                                .toList()
                                .reversed
                                .map(
                                  (DateTime e) => Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      DateFormat(DateFormat.MONTH).format(e),
                                      style:
                                          Theme.of(
                                            context,
                                          ).textTheme.labelLarge,
                                    ),
                                  ),
                                ),
                          ],
                        ),
                        TableRow(
                          children: <Widget>[
                            const Align(
                              alignment: Alignment.center,
                              child: Text(
                                "⬤",
                                style: TextStyle(
                                  color: Colors.green,
                                  textBaseline: TextBaseline.ideographic,
                                  height: 1.3,
                                ),
                              ),
                            ),
                            Text(S.of(context).generalAssets),
                            ...lastMonthsAssets.entries
                                .toList()
                                .reversed
                                .take(3)
                                .toList()
                                .reversed
                                .map(
                                  (MapEntry<DateTime, double> e) => Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      defaultCurrency.fmt(e.value),
                                      style: const TextStyle(
                                        fontFeatures: <FontFeature>[
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                          ],
                        ),
                        TableRow(
                          children: <Widget>[
                            const Align(
                              alignment: Alignment.center,
                              child: Text(
                                "⬤",
                                style: TextStyle(
                                  color: Colors.red,
                                  textBaseline: TextBaseline.ideographic,
                                  height: 1.3,
                                ),
                              ),
                            ),
                            Text(S.of(context).generalLiabilities),
                            ...lastMonthsLiabilities.entries
                                .toList()
                                .reversed
                                .take(3)
                                .toList()
                                .reversed
                                .map(
                                  (MapEntry<DateTime, double> e) => Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      defaultCurrency.fmt(e.value),
                                      style: const TextStyle(
                                        fontFeatures: <FontFeature>[
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                          ],
                        ),
                        TableRow(
                          children: <Widget>[
                            const SizedBox.shrink(),
                            Text(
                              S.of(context).generalSum,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            ...lastMonthsAssets.entries
                                .toList()
                                .reversed
                                .take(3)
                                .toList()
                                .reversed
                                .map((MapEntry<DateTime, double> e) {
                                  final double assets = e.value;
                                  final double liabilities =
                                      lastMonthsLiabilities[e.key] ?? 0;
                                  final double sum = assets + liabilities;
                                  return Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      defaultCurrency.fmt(sum),
                                      style: TextStyle(
                                        color:
                                            (sum < 0)
                                                ? Colors.red
                                                : Colors.green,
                                        fontWeight: FontWeight.bold,
                                        fontFeatures: const <FontFeature>[
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  );
                                }),
                          ],
                        ),
                      ],
                    ),
                child:
                    () => NetWorthChart(
                      assets: lastMonthsAssets,
                      liabilities: lastMonthsLiabilities,
                    ),
              ),
              DashboardCards.budgets => AnimatedHeight(
                child: FutureBuilder<List<BudgetLimitRead>>(
                  future: _fetchBudgets(),
                  builder: (
                    BuildContext context,
                    AsyncSnapshot<List<BudgetLimitRead>> snapshot,
                  ) {
                    if (snapshot.connectionState == ConnectionState.done &&
                        snapshot.hasData) {
                      if (snapshot.data!.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return Card(
                        clipBehavior: Clip.hardEdge,
                        margin: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                S.of(context).homeMainBudgetTitle,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            BudgetList(
                              budgetInfos: budgetInfos,
                              snapshot: snapshot,
                            ),
                          ],
                        ),
                      );
                    } else if (snapshot.hasError) {
                      log.severe(
                        "error fetching budgets",
                        snapshot.error,
                        snapshot.stackTrace,
                      );
                      return Text(snapshot.error!.toString());
                    } else {
                      return const Card(
                        clipBehavior: Clip.hardEdge,
                        margin: EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(4, 4, 4, 12),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      );
                    }
                  },
                ),
              ),
              DashboardCards.bills => AnimatedHeight(
                child: FutureBuilder<List<BillRead>>(
                  future: _fetchBills(),
                  builder: (
                    BuildContext context,
                    AsyncSnapshot<List<BillRead>> snapshot,
                  ) {
                    if (snapshot.connectionState == ConnectionState.done &&
                        snapshot.hasData) {
                      if (snapshot.data!.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return Card(
                        clipBehavior: Clip.hardEdge,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                S.of(context).homeMainBillsTitle,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            BillList(snapshot: snapshot),
                          ],
                        ),
                      );
                    } else if (snapshot.hasError) {
                      log.severe(
                        "error fetching bills",
                        snapshot.error,
                        snapshot.stackTrace,
                      );
                      return Text(snapshot.error!.toString());
                    } else {
                      return const Card(
                        clipBehavior: Clip.hardEdge,
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      );
                    }
                  },
                ),
              ),
            },
          const SizedBox(height: 68),
        ],
      ),
    );
  }
}

class BudgetList extends StatelessWidget {
  const BudgetList({
    super.key,
    required this.budgetInfos,
    required this.snapshot,
  });

  final Map<String, BudgetProperties> budgetInfos;
  final AsyncSnapshot<List<BudgetLimitRead>> snapshot;

  @override
  Widget build(BuildContext context) {
    final TimeZoneHandler tzHandler = context.read<FireflyService>().tzHandler;

    return SizedBox(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final List<Widget> widgets = <Widget>[];
            final int tsNow = tzHandler.sNow().millisecondsSinceEpoch;

            for (BudgetLimitRead budget in snapshot.data!) {
              final List<Widget> stackWidgets = <Widget>[];
              late double spent;
              if (budget.attributes.spent?.isNotEmpty ?? false) {
                spent =
                    (double.tryParse(
                              budget.attributes.spent!.first.sum ?? "",
                            ) ??
                            0)
                        .abs();
              } else {
                spent = 0;
              }
              final double available =
                  double.tryParse(budget.attributes.amount ?? "") ?? 0;

              final int tsStart =
                  tzHandler
                      .sTime(budget.attributes.start!)
                      .millisecondsSinceEpoch;
              final int tsEnd =
                  tzHandler
                      .sTime(budget.attributes.end!)
                      .millisecondsSinceEpoch;
              late double passedDays;
              if (tsEnd == tsStart) {
                passedDays = 2; // Hides the bar
              } else {
                passedDays = (tsNow - tsStart) / (tsEnd - tsStart);
                if (passedDays > 1) {
                  passedDays = 2; // Hides the bar
                }
              }

              final BudgetProperties? budgetInfo =
                  budgetInfos[budget.attributes.budgetId];
              if (budgetInfo == null || available == 0) {
                continue;
              }
              final CurrencyRead currency = CurrencyRead(
                id: budget.attributes.currencyId ?? "0",
                type: "currencies",
                attributes: CurrencyProperties(
                  code: budget.attributes.currencyCode ?? "",
                  name: budget.attributes.currencyName ?? "",
                  symbol: budget.attributes.currencySymbol ?? "",
                  decimalPlaces: budget.attributes.currencyDecimalPlaces,
                ),
              );
              Color lineColor = Colors.green;
              Color? bgColor;
              double value = spent / available;
              if (spent > available) {
                lineColor = Colors.red;
                bgColor = Colors.green;
                value = value % 1;
              }

              if (widgets.isNotEmpty) {
                widgets.add(const SizedBox(height: 8));
              }
              widgets.add(
                RichText(
                  text: TextSpan(
                    children: <InlineSpan>[
                      TextSpan(
                        text: budgetInfo.name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      TextSpan(
                        text:
                            budget.attributes.period?.isNotEmpty ?? false
                                ? S
                                    .of(context)
                                    .homeMainBudgetInterval(
                                      tzHandler
                                          .sTime(budget.attributes.start!)
                                          .toLocal(),
                                      tzHandler
                                          .sTime(budget.attributes.end!)
                                          .toLocal(),
                                      budget.attributes.period!,
                                    )
                                : S
                                    .of(context)
                                    .homeMainBudgetIntervalSingle(
                                      tzHandler
                                          .sTime(budget.attributes.start!)
                                          .toLocal(),
                                      tzHandler
                                          .sTime(budget.attributes.end!)
                                          .toLocal(),
                                    ),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              );
              stackWidgets.add(
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text(
                      S.of(context).numPercent(spent / available),
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge!.copyWith(color: lineColor),
                    ),
                    Text(
                      S
                          .of(context)
                          .homeMainBudgetSum(
                            currency.fmt(
                              (available - spent).abs(),
                              decimalDigits: 0,
                            ),
                            (spent > available) ? "over" : "leftfrom",
                            currency.fmt(available, decimalDigits: 0),
                          ),
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge!.copyWith(color: lineColor),
                    ),
                  ],
                ),
              );
              stackWidgets.add(
                Positioned.fill(
                  top: 20, // Height of Row() with text
                  bottom: 4,
                  child: LinearProgressIndicator(
                    color: lineColor,
                    backgroundColor: bgColor,
                    value: value,
                  ),
                ),
              );
              widgets.add(
                LayoutBuilder(
                  builder:
                      (BuildContext context, BoxConstraints constraints) =>
                          Stack(
                            children: <Widget>[
                              // Row + ProgressIndicator + Bottom Padding
                              const SizedBox(height: 20 + 4 + 4),
                              ...stackWidgets,
                              Positioned(
                                left: constraints.biggest.width * passedDays,
                                top: 16,
                                bottom: 0,
                                width: 3,
                                child: Container(
                                  color:
                                      (spent / available > passedDays)
                                          ? Colors.redAccent
                                          : Colors.blueAccent,
                                ),
                              ),
                            ],
                          ),
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widgets,
            );
          },
        ),
      ),
    );
  }
}

class BillList extends StatelessWidget {
  const BillList({super.key, required this.snapshot});

  final AsyncSnapshot<List<BillRead>> snapshot;

  @override
  Widget build(BuildContext context) {
    final TimeZoneHandler tzHandler = context.read<FireflyService>().tzHandler;

    return SizedBox(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final List<Widget> widgets = <Widget>[];
            snapshot.data!.sort((BillRead a, BillRead b) {
              final int dateCompare = (a.attributes.nextExpectedMatch ??
                      tzHandler.sNow())
                  .compareTo(
                    b.attributes.nextExpectedMatch ?? tzHandler.sNow(),
                  );
              if (dateCompare != 0) {
                return dateCompare;
              }
              final int orderCompare = (a.attributes.order ?? 0).compareTo(
                b.attributes.order ?? 0,
              );
              if (orderCompare != 0) {
                return orderCompare;
              }
              return a.attributes.avgAmount().compareTo(
                b.attributes.avgAmount(),
              );
            });

            DateTime lastDate = (snapshot
                        .data!
                        .first
                        .attributes
                        .nextExpectedMatch ??
                    tzHandler.sNow())
                .subtract(const Duration(days: 1));
            for (BillRead bill in snapshot.data!) {
              if (!(bill.attributes.active ?? false)) {
                continue;
              }

              final DateTime nextMatch =
                  bill.attributes.nextExpectedMatch != null
                      ? tzHandler
                          .sTime(bill.attributes.nextExpectedMatch!)
                          .toLocal()
                      : tzHandler.sNow();
              final CurrencyRead currency = CurrencyRead(
                id: bill.attributes.currencyId ?? "0",
                type: "currencies",
                attributes: CurrencyProperties(
                  code: bill.attributes.currencyCode ?? "",
                  name: "",
                  symbol: bill.attributes.currencySymbol ?? "",
                  decimalPlaces: bill.attributes.currencyDecimalPlaces,
                ),
              );

              if (nextMatch != lastDate) {
                if (widgets.isNotEmpty) {
                  widgets.add(const SizedBox(height: 8));
                }
                widgets.add(
                  Text(
                    DateFormat.yMd().format(nextMatch),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                );
                lastDate = nextMatch;
              }
              widgets.add(
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    RichText(
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      text: TextSpan(
                        children: <InlineSpan>[
                          TextSpan(
                            text:
                                bill.attributes.name!.length > 30
                                    ? bill.attributes.name!.replaceRange(
                                      30,
                                      bill.attributes.name!.length,
                                      "…",
                                    )
                                    : bill.attributes.name,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          TextSpan(
                            text: S
                                .of(context)
                                .homeMainBillsInterval(
                                  bill.attributes.repeatFreq!.value ?? "",
                                ),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    Text(
                      currency.fmt(bill.attributes.avgAmount()),
                      style: const TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.bold,
                        fontFeatures: <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widgets,
            );
          },
        ),
      ),
    );
  }
}

class ChartCard extends StatelessWidget {
  const ChartCard({
    super.key,
    required this.title,
    required this.child,
    required this.future,
    this.height = 150,
    this.summary,
    this.onTap,
  });

  final String title;
  final Widget Function() child;
  final Future<bool> future;
  final Widget Function()? summary;
  final double height;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    final Logger log = Logger("Pages.Home.Main.ChartCard");
    final List<Widget> summaryWidgets = <Widget>[];

    return AnimatedHeight(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Card(
          clipBehavior: Clip.hardEdge,
          child: FutureBuilder<bool>(
            future: future,
            builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
              if (snapshot.connectionState == ConnectionState.done &&
                  snapshot.hasData) {
                if (summary != null) {
                  summaryWidgets.add(const Divider(indent: 16, endIndent: 16));
                  summaryWidgets.add(
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: summary!(),
                    ),
                  );
                }
                return InkWell(
                  onTap: onTap,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: <Widget>[
                            Text(
                              title,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            onTap != null
                                ? Icon(
                                  Icons.touch_app_outlined,
                                  color:
                                      Theme.of(
                                        context,
                                      ).colorScheme.outlineVariant,
                                )
                                : const SizedBox.shrink(),
                          ],
                        ),
                      ),
                      Ink(
                        decoration: BoxDecoration(
                          color:
                              Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                        ),
                        child: SizedBox(
                          height: height,
                          child:
                              onTap != null
                                  // AbsorbPointer fixes SfChart invalidating the onTap feedback
                                  ? AbsorbPointer(child: child())
                                  : child(),
                        ),
                      ),
                      ...summaryWidgets,
                    ],
                  ),
                );
              } else if (snapshot.hasError) {
                log.severe(
                  "error getting chart card data",
                  snapshot.error,
                  snapshot.stackTrace,
                );
                return Text(snapshot.error!.toString());
              } else {
                return const Padding(
                  padding: EdgeInsets.all(8),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
            },
          ),
        ),
      ),
    );
  }
}
