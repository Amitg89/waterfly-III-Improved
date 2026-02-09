import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:waterflyiii/extensions.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/pages/bills.dart';

final Logger log = Logger("Settings");

class NotificationAppSettings {
  NotificationAppSettings(
    this.appName, {
    this.defaultAccountId,
    this.includeTitle = true,
    this.autoAdd = false,
    this.emptyNote = false,
  });

  final String appName;
  String? defaultAccountId;
  bool includeTitle = true;
  bool autoAdd = false;
  bool emptyNote = false;

  NotificationAppSettings.fromJson(Map<String, dynamic> json)
    : appName = json['appName'],
      defaultAccountId = json['defaultAccountId'],
      includeTitle = json['includeTitle'] ?? true,
      autoAdd = json['autoAdd'] ?? false,
      emptyNote = json['emptyNote'] ?? false;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'appName': appName,
    'defaultAccountId': defaultAccountId,
    'includeTitle': includeTitle,
    'autoAdd': autoAdd,
    'emptyNote': emptyNote,
  };
}

// in default order
enum DashboardCards {
  dailyavg,
  categories,
  tags,
  accounts,
  chargesPerCard,
  netearnings,
  networth,
  budgets,
  bills,
}

enum BoolSettings {
  debug,
  lock,
  showFutureTXs,
  dynamicColors,
  useServerTime,
  hideTags,
  billsShowOnlyActive,
  billsShowOnlyExpected,
}

enum TransactionDateFilter {
  currentMonth,
  last30Days,
  currentYear,
  lastYear,
  all,
  custom,
}

enum DashboardDateRange {
  last7Days,
  last30Days,
  currentMonth,
  last3Months,
  last12Months,
  custom,
}

class SettingsBitmask {
  int _value;

  SettingsBitmask([this._value = 0]) {
    assert(_value >= 0);
  }

  bool operator [](BoolSettings flag) => hasFlag(flag);

  void operator []=(BoolSettings flag, bool value) {
    if (value) {
      setFlag(flag);
    } else {
      unsetFlag(flag);
    }
  }

  bool hasFlag(BoolSettings flag) => (_value & (1 << flag.index)) != 0;

  void setFlag(BoolSettings flag) {
    _value |= 1 << flag.index;
  }

  void unsetFlag(BoolSettings flag) {
    _value &= ~(1 << flag.index);
  }

  int get value => _value;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer();
    for (final BoolSettings flag in BoolSettings.values.reversed) {
      if (hasFlag(flag)) {
        buffer.write('1');
      } else {
        buffer.write('0');
      }
    }
    return buffer.toString();
  }
}

class SettingsProvider with ChangeNotifier {
  static const String settingsBitmask = "BOOLBITMASK";
  static const String settingDebug = "DEBUG";
  static const String settingLocale = "LOCALE";
  static const String settingLock = "LOCK";
  static const String settingShowFutureTXs = "SHOWFUTURETXS";
  static const String settingNLKnownApps = "NL_KNOWNAPPS";
  static const String settingNLUsedApps = "NL_USEDAPPS";
  static const String settingNLAppPrefix = "NL_APP_";
  static const String settingTheme = "THEME";
  static const String settingThemeDark = "DARK";
  static const String settingThemeLight = "LIGHT";
  static const String settingThemeSystem = "SYSTEM";
  static const String settingDynamicColors = "DYNAMICCOLORS";
  static const String settingUseServerTime = "USESERVERTIME";
  static const String settingBillsDefaultLayout = "BILLSDEFAULTLAYOUT";
  static const String settingBillsDefaultSort = "BILLSDEFAULTSORT";
  static const String settingBillsDefaultSortOrder = "BILLSDEFAULTSORTORDER";
  static const String settingsCategoriesSumExcluded = "CAT_SUMEXCLUDED";
  static const String settingsDashboardOrder = "DASHBOARD_ORDER";
  static const String settingsDashboardHidden = "DASHBOARD_HIDDEN";
  static const String settingTransactionDateFilter = "TX_DATE_FILTER";
  static const String settingTransactionDateRangeStart = "TX_DATE_RANGE_START";
  static const String settingTransactionDateRangeEnd = "TX_DATE_RANGE_END";
  static const String settingDashboardDateRange = "DASHBOARD_DATE_RANGE";
  static const String settingDashboardDateRangeStart =
      "DASHBOARD_DATE_RANGE_START";
  static const String settingDashboardDateRangeEnd = "DASHBOARD_DATE_RANGE_END";
  static const String settingDashboardAccountIds = "DASHBOARD_ACCOUNT_IDS";

  bool get debug => _loaded ? _boolSettings[BoolSettings.debug] : false;
  bool get lock => _loaded ? _boolSettings[BoolSettings.lock] : false;
  bool get showFutureTXs =>
      _loaded ? _boolSettings[BoolSettings.showFutureTXs] : false;
  bool get dynamicColors =>
      _loaded ? _boolSettings[BoolSettings.dynamicColors] : false;
  bool get useServerTime =>
      _loaded ? _boolSettings[BoolSettings.useServerTime] : true;
  bool get hideTags => _loaded ? _boolSettings[BoolSettings.hideTags] : false;
  bool get billsShowOnlyActive =>
      _loaded ? _boolSettings[BoolSettings.billsShowOnlyActive] : false;
  bool get billsShowOnlyExpected =>
      _loaded ? _boolSettings[BoolSettings.billsShowOnlyExpected] : false;

  ThemeMode _theme = ThemeMode.system;
  ThemeMode get theme => _theme;

  Locale? _locale;
  Locale? get locale => _locale;

  StreamSubscription<LogRecord>? _debugLogger;

  bool _loaded = false;
  bool get loaded => _loaded;

  bool _loading = false;

  List<String> _notificationApps = <String>[];
  List<String> get notificationApps => _notificationApps;

  BillsLayout _billsLayout = BillsLayout.grouped;
  BillsLayout get billsLayout => _billsLayout;
  BillsSort _billsSort = BillsSort.name;
  BillsSort get billsSort => _billsSort;
  SortingOrder _billsSortOrder = SortingOrder.ascending;
  SortingOrder get billsSortOrder => _billsSortOrder;

  List<String> _categoriesSumExcluded = <String>[];
  List<String> get categoriesSumExcluded => _categoriesSumExcluded;

  List<DashboardCards> _dashboardOrder = <DashboardCards>[];
  List<DashboardCards> get dashboardOrder => _dashboardOrder;

  final List<DashboardCards> _dashboardHidden = <DashboardCards>[];
  List<DashboardCards> get dashboardHidden => _dashboardHidden;

  late SettingsBitmask _boolSettings;
  SettingsBitmask get boolSettings => _boolSettings;

  TransactionDateFilter _transactionDateFilter = TransactionDateFilter.all;
  DateTime? _transactionDateRangeStart;
  DateTime? _transactionDateRangeEnd;

  TransactionDateFilter get transactionDateFilter => _transactionDateFilter;
  DateTime? get transactionDateRangeStart => _transactionDateRangeStart;
  DateTime? get transactionDateRangeEnd => _transactionDateRangeEnd;

  DashboardDateRange _dashboardDateRange = DashboardDateRange.last3Months;
  DateTime? _dashboardDateRangeStart;
  DateTime? _dashboardDateRangeEnd;
  List<String> _dashboardAccountIds = <String>[];

  DashboardDateRange get dashboardDateRange => _dashboardDateRange;
  DateTime? get dashboardDateRangeStart => _dashboardDateRangeStart;
  DateTime? get dashboardDateRangeEnd => _dashboardDateRangeEnd;
  List<String> get dashboardAccountIds => List<String>.unmodifiable(_dashboardAccountIds);

  Future<void> migrateLegacy(SharedPreferencesAsync prefs) async {
    log.config("trying to migrate old prefs");
    final SharedPreferences oldPrefs = await SharedPreferences.getInstance();

    _boolSettings = SettingsBitmask(oldPrefs.getInt(settingsBitmask) ?? 0);
    if (!oldPrefs.containsKey(settingsBitmask)) {
      // Fallback solution for migration
      log.config("no bitmask saved, trying legacy settings");
      _boolSettings[BoolSettings.debug] =
          oldPrefs.getBool(settingDebug) ?? false;
      _boolSettings[BoolSettings.lock] = oldPrefs.getBool(settingLock) ?? false;
      _boolSettings[BoolSettings.showFutureTXs] =
          oldPrefs.getBool(settingShowFutureTXs) ?? false;
      _boolSettings[BoolSettings.dynamicColors] =
          oldPrefs.getBool(settingDynamicColors) ?? false;
      _boolSettings[BoolSettings.useServerTime] =
          oldPrefs.getBool(settingUseServerTime) ?? true;
      _boolSettings[BoolSettings.hideTags] = false;
      _boolSettings[BoolSettings.billsShowOnlyActive] = false;
      _boolSettings[BoolSettings.billsShowOnlyExpected] = false;
    }
    await prefs.setInt(settingsBitmask, _boolSettings.value);

    final String? theme = oldPrefs.getString(settingTheme);
    if (theme != null) {
      await prefs.setString(settingTheme, theme);
    }

    final String? locale = oldPrefs.getString(settingLocale);
    if (locale != null) {
      await prefs.setString(settingLocale, locale);
    }

    final List<String>? notificationApps = oldPrefs.getStringList(
      settingNLUsedApps,
    );
    if (notificationApps != null) {
      await prefs.setStringList(settingNLUsedApps, notificationApps);
    }

    final int? billsLayoutIndex = oldPrefs.getInt(settingBillsDefaultLayout);
    if (billsLayoutIndex != null) {
      await prefs.setInt(settingBillsDefaultLayout, billsLayoutIndex);
    }

    final int? billsSortIndex = oldPrefs.getInt(settingBillsDefaultSort);
    if (billsSortIndex != null) {
      await prefs.setInt(settingBillsDefaultSort, billsSortIndex);
    }

    final int? billsSortOrderIndex = oldPrefs.getInt(
      settingBillsDefaultSortOrder,
    );
    if (billsSortOrderIndex != null) {
      await prefs.setInt(settingBillsDefaultSortOrder, billsSortOrderIndex);
    }

    final List<String>? categoriesSumExcluded = oldPrefs.getStringList(
      settingsCategoriesSumExcluded,
    );
    if (categoriesSumExcluded != null) {
      await prefs.setStringList(
        settingsCategoriesSumExcluded,
        categoriesSumExcluded,
      );
    }

    // Migrate notification settings
    final List<String>? knownApps = oldPrefs.getStringList(settingNLKnownApps);
    if (knownApps != null) {
      await prefs.setStringList(settingNLKnownApps, knownApps);
    }
    final List<String>? usedApps = oldPrefs.getStringList(settingNLUsedApps);
    if (usedApps != null) {
      await prefs.setStringList(settingNLUsedApps, usedApps);
      for (String packageName in usedApps) {
        final String? json = oldPrefs.getString(
          "$settingNLAppPrefix$packageName",
        );
        if (json == null) {
          continue;
        }
        await prefs.setString("$settingNLAppPrefix$packageName", json);
      }
    }
  }

  Future<void> loadSettings() async {
    if (_loading) {
      log.config("already loading prefs, skipping this call");
      return;
    }
    _loading = true;

    final SharedPreferencesAsync prefs = SharedPreferencesAsync();
    log.config("reading prefs");

    _boolSettings = SettingsBitmask(await prefs.getInt(settingsBitmask) ?? 0);
    if (!await prefs.containsKey(settingsBitmask)) {
      await migrateLegacy(prefs);
    }
    _boolSettings = SettingsBitmask(await prefs.getInt(settingsBitmask) ?? 0);
    log.config("read bool bitmask $_boolSettings");

    final String theme = await prefs.getString(settingTheme) ?? "unset";
    log.config("read theme $theme");
    switch (theme) {
      case settingThemeDark:
        _theme = ThemeMode.dark;
        break;
      case settingThemeLight:
        _theme = ThemeMode.light;
        break;
      case settingThemeSystem:
      default:
        _theme = ThemeMode.system;
    }

    final String localeStr = await prefs.getString(settingLocale) ?? "unset";
    log.config("read locale $localeStr");
    final Locale locale = LocaleExt.fromLanguageTag(localeStr);
    if (S.supportedLocales.contains(locale)) {
      _locale = locale;
      late String? countryCode;
      if (locale.countryCode?.isEmpty ?? true) {
        countryCode = Intl.defaultLocale?.split("_").last;
      } else {
        countryCode = locale.countryCode;
      }
      Intl.defaultLocale = "${locale.languageCode}_$countryCode";
    } else {
      _locale = const Locale('en');
    }

    if (debug) {
      log.config("setting debug");
      Logger.root.level = Level.ALL;
      _debugLogger = Logger.root.onRecord.listen(await DebugLogger().get());
    } else {
      log.config("not setting debug");
      Logger.root.level = kDebugMode ? Level.ALL : Level.INFO;
    }

    _notificationApps =
        await prefs.getStringList(settingNLUsedApps) ?? <String>[];

    final int? billsLayoutIndex = await prefs.getInt(settingBillsDefaultLayout);
    _billsLayout =
        billsLayoutIndex == null
            ? BillsLayout.grouped
            : BillsLayout.values[billsLayoutIndex];

    final int? billsSortIndex = await prefs.getInt(settingBillsDefaultSort);
    _billsSort =
        billsSortIndex == null
            ? BillsSort.name
            : BillsSort.values[billsSortIndex];

    final int? billsSortOrderIndex = await prefs.getInt(
      settingBillsDefaultSortOrder,
    );
    _billsSortOrder =
        billsSortOrderIndex == null
            ? SortingOrder.ascending
            : SortingOrder.values[billsSortOrderIndex];

    _categoriesSumExcluded =
        await prefs.getStringList(settingsCategoriesSumExcluded) ?? <String>[];

    final List<String> dashboardOrderStr =
        await prefs.getStringList(settingsDashboardOrder) ?? <String>[];
    for (String s in dashboardOrderStr) {
      _dashboardOrder.add(
        DashboardCards.values.firstWhere((DashboardCards e) => e.name == s),
      );
    }

    // Always filter out dupes.
    _dashboardOrder = dashboardOrder.toSet().toList();

    if (dashboardOrder.isEmpty ||
        DashboardCards.values.length < dashboardOrder.length) {
      // No order saved or too many items --> use default order
      _dashboardOrder = List<DashboardCards>.from(DashboardCards.values);
    } else if (DashboardCards.values.length > dashboardOrder.length) {
      // Too few items, maybe a new card was added. Add missing items.
      for (DashboardCards s in DashboardCards.values) {
        if (!dashboardOrder.contains(s)) {
          _dashboardOrder.add(s);
        }
      }
    }

    final List<String>? dashboardHiddenStr = await prefs.getStringList(
      settingsDashboardHidden,
    );
    if (dashboardHiddenStr == null) {
      // Default hidden charts
      _dashboardHidden.add(DashboardCards.tags);
    } else {
      for (String s in dashboardHiddenStr) {
        _dashboardHidden.add(
          DashboardCards.values.firstWhere((DashboardCards e) => e.name == s),
        );
      }
    }

    final int? dashboardDateRangeIndex =
        await prefs.getInt(settingDashboardDateRange);
    _dashboardDateRange =
        dashboardDateRangeIndex == null
            ? DashboardDateRange.last3Months
            : (dashboardDateRangeIndex >= 0 &&
                    dashboardDateRangeIndex < DashboardDateRange.values.length)
                ? DashboardDateRange.values[dashboardDateRangeIndex]
                : DashboardDateRange.last3Months;

    final String? dashboardRangeStartStr =
        await prefs.getString(settingDashboardDateRangeStart);
    final String? dashboardRangeEndStr =
        await prefs.getString(settingDashboardDateRangeEnd);
    if (dashboardRangeStartStr != null && dashboardRangeEndStr != null) {
      try {
        _dashboardDateRangeStart = DateTime.parse(dashboardRangeStartStr);
        _dashboardDateRangeEnd = DateTime.parse(dashboardRangeEndStr);
      } catch (_) {
        _dashboardDateRangeStart = null;
        _dashboardDateRangeEnd = null;
      }
    } else {
      _dashboardDateRangeStart = null;
      _dashboardDateRangeEnd = null;
    }

    _dashboardAccountIds =
        await prefs.getStringList(settingDashboardAccountIds) ?? <String>[];

    // Load new transaction date filter setting
    final int? txDateFilterIndex = await prefs.getInt(
      settingTransactionDateFilter,
    );
    _transactionDateFilter =
        txDateFilterIndex == null
            ? TransactionDateFilter.all
            : (txDateFilterIndex >= 0 && txDateFilterIndex < TransactionDateFilter.values.length)
                ? TransactionDateFilter.values[txDateFilterIndex]
                : TransactionDateFilter.all;

    // Load custom date range when filter is custom
    final String? rangeStartStr = await prefs.getString(settingTransactionDateRangeStart);
    final String? rangeEndStr = await prefs.getString(settingTransactionDateRangeEnd);
    if (rangeStartStr != null && rangeEndStr != null) {
      try {
        _transactionDateRangeStart = DateTime.parse(rangeStartStr);
        _transactionDateRangeEnd = DateTime.parse(rangeEndStr);
      } catch (_) {
        _transactionDateRangeStart = null;
        _transactionDateRangeEnd = null;
      }
    } else {
      _transactionDateRangeStart = null;
      _transactionDateRangeEnd = null;
    }

    _loaded = _loading = true;
    log.finest(() => "notify SettingsProvider->loadSettings()");
    notifyListeners();
  }

  bool _setBool(BoolSettings setting, bool value) {
    if (_boolSettings[setting] == value) {
      return false;
    }

    _boolSettings[setting] = value;

    () async {
      await SharedPreferencesAsync().setInt(
        settingsBitmask,
        _boolSettings.value,
      );

      log.finest(() => "notify SettingsProvider->_setBool($setting)");
      notifyListeners();
    }();

    return true;
  }

  // Bool setters
  set debug(bool enabled) {
    if (!_setBool(BoolSettings.debug, enabled)) {
      return;
    }

    () async {
      if (debug) {
        Logger.root.level = Level.ALL;
        _debugLogger = Logger.root.onRecord.listen(await DebugLogger().get());
        final PackageInfo appInfo = await PackageInfo.fromPlatform();
        log.info(
          "Enabling debug logs, app ${appInfo.appName} v${appInfo.version}+${appInfo.buildNumber}",
        );
      } else {
        Logger.root.level = kDebugMode ? Level.ALL : Level.INFO;
        await _debugLogger?.cancel();
        await DebugLogger().destroy();
      }
    }();
  }

  set lock(bool enabled) => _setBool(BoolSettings.lock, enabled);
  set showFutureTXs(bool enabled) =>
      _setBool(BoolSettings.showFutureTXs, enabled);
  set dynamicColors(bool enabled) =>
      _setBool(BoolSettings.dynamicColors, enabled);
  set useServerTime(bool enabled) =>
      _setBool(BoolSettings.useServerTime, enabled);
  set hideTags(bool enabled) => _setBool(BoolSettings.hideTags, enabled);
  set billsShowOnlyActive(bool enabled) =>
      _setBool(BoolSettings.billsShowOnlyActive, enabled);
  set billsShowOnlyExpected(bool enabled) =>
      _setBool(BoolSettings.billsShowOnlyExpected, enabled);

  Future<void> setTheme(ThemeMode theme) async {
    _theme = theme;
    switch (theme) {
      case ThemeMode.dark:
        await SharedPreferencesAsync().setString(
          settingTheme,
          settingThemeDark,
        );
        break;
      case ThemeMode.light:
        await SharedPreferencesAsync().setString(
          settingTheme,
          settingThemeLight,
        );
        break;
      case ThemeMode.system:
        await SharedPreferencesAsync().setString(
          settingTheme,
          settingThemeSystem,
        );
    }

    log.finest(() => "notify SettingsProvider->setTheme()");
    notifyListeners();
  }

  Future<void> setLocale(Locale locale) async {
    if (!S.supportedLocales.contains(locale)) {
      return;
    }

    _locale = locale;
    late String? countryCode;
    if (locale.countryCode?.isEmpty ?? true) {
      countryCode = Intl.defaultLocale?.split("_").last;
    } else {
      countryCode = locale.countryCode;
    }
    Intl.defaultLocale = "${locale.languageCode}_$countryCode";
    await SharedPreferencesAsync().setString(
      settingLocale,
      locale.toLanguageTag(),
    );

    log.finest(() => "notify SettingsProvider->setLocale()");
    notifyListeners();
  }

  Future<void> notificationAddKnownApp(String packageName) async {
    final SharedPreferencesAsync prefs = SharedPreferencesAsync();
    final List<String> apps =
        await prefs.getStringList(settingNLKnownApps) ?? <String>[];

    if (packageName.isEmpty || apps.contains(packageName)) {
      return;
    }

    apps.add(packageName);
    return prefs.setStringList(settingNLKnownApps, apps);
  }

  Future<List<String>> notificationKnownApps({bool filterUsed = false}) async {
    final List<String> apps =
        await SharedPreferencesAsync().getStringList(settingNLKnownApps) ??
        <String>[];
    if (filterUsed) {
      final List<String> knownApps = await notificationUsedApps();
      return apps
          .where((String element) => !knownApps.contains(element))
          .toList();
    }

    return apps;
  }

  Future<bool> notificationAddUsedApp(String packageName) async {
    final SharedPreferencesAsync prefs = SharedPreferencesAsync();
    final List<String> apps =
        await prefs.getStringList(settingNLUsedApps) ?? <String>[];

    if (packageName.isEmpty || apps.contains(packageName)) {
      return false;
    }

    apps.add(packageName);
    await prefs.setStringList(settingNLUsedApps, apps);

    _notificationApps = apps;

    log.finest(() => "notify SettingsProvider->notificationAddUsedApp()");
    notifyListeners();
    return true;
  }

  Future<bool> notificationRemoveUsedApp(String packageName) async {
    final SharedPreferencesAsync prefs = SharedPreferencesAsync();
    final List<String> apps =
        await prefs.getStringList(settingNLUsedApps) ?? <String>[];

    if (packageName.isEmpty || !apps.contains(packageName)) {
      return false;
    }

    apps.remove(packageName);
    await prefs.remove("$settingNLAppPrefix$packageName");
    await prefs.setStringList(settingNLUsedApps, apps);

    _notificationApps = apps;

    log.finest(() => "notify SettingsProvider->notificationRemoveUsedApp()");

    notifyListeners();
    return true;
  }

  Future<List<String>> notificationUsedApps() async {
    final List<String> apps =
        await SharedPreferencesAsync().getStringList(settingNLUsedApps) ??
        <String>[];
    if (!const ListEquality<String>().equals(apps, _notificationApps)) {
      _notificationApps = apps;

      log.finest(() => "notify SettingsProvider->notificationUsedApps()");
      notifyListeners();
    }

    return _notificationApps;
  }

  Future<NotificationAppSettings> notificationGetAppSettings(
    String packageName,
  ) async {
    final String json =
        await SharedPreferencesAsync().getString(
          "$settingNLAppPrefix$packageName",
        ) ??
        "";
    try {
      return NotificationAppSettings.fromJson(jsonDecode(json));
    } on FormatException catch (_) {
      return NotificationAppSettings(packageName);
    }
  }

  Future<void> notificationSetAppSettings(
    String packageName,
    NotificationAppSettings settings,
  ) async {
    await SharedPreferencesAsync().setString(
      "$settingNLAppPrefix$packageName",
      jsonEncode(settings),
    );
  }

  Future<void> setBillsLayout(BillsLayout billsLayout) async {
    if (billsLayout == _billsLayout) {
      return;
    }

    _billsLayout = billsLayout;
    await SharedPreferencesAsync().setInt(
      settingBillsDefaultLayout,
      billsLayout.index,
    );

    log.finest(() => "notify SettingsProvider->billsLayout()");
    notifyListeners();
  }

  Future<void> setBillsSort(BillsSort billsSort) async {
    if (billsSort == _billsSort) {
      return;
    }

    _billsSort = billsSort;
    await SharedPreferencesAsync().setInt(
      settingBillsDefaultSort,
      billsSort.index,
    );

    log.finest(() => "notify SettingsProvider->billsSort()");
    notifyListeners();
  }

  Future<void> setBillsSortOrder(SortingOrder sortOrder) async {
    if (sortOrder == _billsSortOrder) {
      return;
    }

    _billsSortOrder = sortOrder;
    await SharedPreferencesAsync().setInt(
      settingBillsDefaultSortOrder,
      sortOrder.index,
    );

    log.finest(() => "notify SettingsProvider->billsSortOrder()");
    notifyListeners();
  }

  Future<void> categoryAddSumExcluded(String categoryId) async {
    if (categoryId.isEmpty || categoriesSumExcluded.contains(categoryId)) {
      return;
    }

    _categoriesSumExcluded.add(categoryId);
    await SharedPreferencesAsync().setStringList(
      settingsCategoriesSumExcluded,
      categoriesSumExcluded,
    );

    log.finest(() => "notify SettingsProvider->categoryAddSumExcluded()");
    notifyListeners();
  }

  Future<void> categoryRemoveSumExcluded(String categoryId) async {
    if (categoryId.isEmpty || !categoriesSumExcluded.contains(categoryId)) {
      return;
    }

    _categoriesSumExcluded.remove(categoryId);
    await SharedPreferencesAsync().setStringList(
      settingsCategoriesSumExcluded,
      categoriesSumExcluded,
    );

    log.finest(() => "notify SettingsProvider->categoryRemoveSumExcluded()");
    notifyListeners();
  }

  Future<void> setDashboardOrder(List<DashboardCards> order) async {
    final List<String> orderStr = <String>[];
    for (DashboardCards e in order) {
      if (orderStr.contains(e.name)) {
        continue;
      }
      orderStr.add(e.name);
    }

    _dashboardOrder = order;
    await SharedPreferencesAsync().setStringList(
      settingsDashboardOrder,
      orderStr,
    );

    log.finest(() => "notify SettingsProvider->setDashboardOrder()");
    notifyListeners();
  }

  Future<void> dashboardHideCard(DashboardCards card) async {
    if (dashboardHidden.contains(card)) {
      return;
    }
    _dashboardHidden.add(card);

    final List<String> hiddenStr = <String>[];
    for (DashboardCards e in dashboardHidden) {
      hiddenStr.add(e.name);
    }
    await SharedPreferencesAsync().setStringList(
      settingsDashboardHidden,
      hiddenStr,
    );

    log.finest(() => "notify SettingsProvider->dashboardHideCard()");
    notifyListeners();
  }

  Future<void> dashboardShowCard(DashboardCards card) async {
    if (!dashboardHidden.contains(card)) {
      return;
    }
    _dashboardHidden.remove(card);

    final List<String> hiddenStr = <String>[];
    for (DashboardCards e in dashboardHidden) {
      hiddenStr.add(e.name);
    }
    await SharedPreferencesAsync().setStringList(
      settingsDashboardHidden,
      hiddenStr,
    );

    log.finest(() => "notify SettingsProvider->dashboardShowCard()");
    notifyListeners();
  }

  Future<void> setTransactionDateFilter(TransactionDateFilter filter) async {
    if (filter == _transactionDateFilter) {
      return;
    }

    _transactionDateFilter = filter;
    await SharedPreferencesAsync().setInt(
      settingTransactionDateFilter,
      filter.index,
    );

    log.finest(() => "notify SettingsProvider->setTransactionDateFilter()");
    notifyListeners();
  }

  Future<void> setTransactionDateRange(DateTime start, DateTime end) async {
    if (_transactionDateRangeStart == start && _transactionDateRangeEnd == end) {
      return;
    }

    _transactionDateRangeStart = start;
    _transactionDateRangeEnd = end;
    await SharedPreferencesAsync().setString(
      settingTransactionDateRangeStart,
      DateFormat('yyyy-MM-dd').format(start),
    );
    await SharedPreferencesAsync().setString(
      settingTransactionDateRangeEnd,
      DateFormat('yyyy-MM-dd').format(end),
    );

    log.finest(() => "notify SettingsProvider->setTransactionDateRange()");
    notifyListeners();
  }

  Future<void> setDashboardDateRange(DashboardDateRange range) async {
    if (range == _dashboardDateRange) {
      return;
    }
    _dashboardDateRange = range;
    await SharedPreferencesAsync().setInt(
      settingDashboardDateRange,
      range.index,
    );
    log.finest(() => "notify SettingsProvider->setDashboardDateRange()");
    notifyListeners();
  }

  Future<void> setDashboardDateRangeCustom(DateTime start, DateTime end) async {
    if (_dashboardDateRangeStart == start && _dashboardDateRangeEnd == end) {
      return;
    }
    _dashboardDateRangeStart = start;
    _dashboardDateRangeEnd = end;
    await SharedPreferencesAsync().setString(
      settingDashboardDateRangeStart,
      DateFormat('yyyy-MM-dd').format(start),
    );
    await SharedPreferencesAsync().setString(
      settingDashboardDateRangeEnd,
      DateFormat('yyyy-MM-dd').format(end),
    );
    log.finest(() => "notify SettingsProvider->setDashboardDateRangeCustom()");
    notifyListeners();
  }

  Future<void> setDashboardAccountIds(List<String> ids) async {
    if (listEquals(_dashboardAccountIds, ids)) {
      return;
    }
    _dashboardAccountIds = List<String>.from(ids);
    await SharedPreferencesAsync().setStringList(
      settingDashboardAccountIds,
      _dashboardAccountIds,
    );
    log.finest(() => "notify SettingsProvider->setDashboardAccountIds()");
    notifyListeners();
  }

  /// Returns the start and end date for the dashboard based on current range.
  (DateTime start, DateTime end) getDashboardDateRange(DateTime now) {
    late DateTime start;
    late DateTime end;
    switch (_dashboardDateRange) {
      case DashboardDateRange.last7Days:
        start = now.subtract(const Duration(days: 6));
        end = now;
        break;
      case DashboardDateRange.last30Days:
        start = now.subtract(const Duration(days: 30));
        end = now;
        break;
      case DashboardDateRange.currentMonth:
        start = now.copyWith(day: 1);
        end = now;
        break;
      case DashboardDateRange.last3Months:
        final int m3 = now.month - 3;
        start = DateTime(
          now.year + (m3 <= 0 ? -1 : 0),
          m3 <= 0 ? m3 + 12 : m3,
          1,
        );
        end = now;
        break;
      case DashboardDateRange.last12Months:
        final int m12 = now.month - 12;
        start = DateTime(
          now.year + (m12 <= 0 ? -1 : 0),
          m12 <= 0 ? m12 + 12 : m12,
          1,
        );
        end = now;
        break;
      case DashboardDateRange.custom:
        start = _dashboardDateRangeStart ??
            now.subtract(const Duration(days: 30));
        end = _dashboardDateRangeEnd ?? now;
        break;
    }
    return (start, end);
  }
}

class DebugLogger {
  String? _logPath;

  Future<Function(LogRecord)> get() async {
    _logPath = await _getPath();
    return _log;
  }

  Future<String> _getPath() async {
    final Directory tmpPath = await getTemporaryDirectory();
    return "${tmpPath.path}/debuglog.txt";
  }

  void _log(LogRecord record) {
    if (_logPath?.isEmpty ?? true) {
      return;
    }
    String message = record.message;
    if (record.error != null) {
      message += "\nERROR MESSAGE: ${record.error}";
    }
    if (record.stackTrace != null) {
      message += "\nSTACKTRACE:\n${record.stackTrace}\n\n";
    }
    File(_logPath!).writeAsStringSync(
      "${record.time}: [${record.loggerName} - ${record.level.name}] $message\n",
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<void> destroy() async {
    final File file = File(await _getPath());
    if (await file.exists()) {
      file.deleteSync();
    }
  }
}
