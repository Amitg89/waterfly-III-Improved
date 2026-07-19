import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/pages/home/banks.dart';
import 'package:waterflyiii/pages/home/cards.dart';
import 'package:waterflyiii/pages/home/overview.dart';
import 'package:waterflyiii/pages/home/mortgage.dart';
import 'package:waterflyiii/pages/home/savings.dart';
import 'package:waterflyiii/pages/navigation.dart';
import 'package:waterflyiii/settings.dart';
import 'package:waterflyiii/widgets/fabs.dart';
import 'package:waterflyiii/widgets/vault_bottom_nav.dart';

final Logger log = Logger("Pages.Home");

class PageActions extends ChangeNotifier {
  final Map<Key, List<Widget>> _map = <Key, List<Widget>>{};
  List<Widget>? get(Key key) => _map[key];

  final Logger log = Logger("Pages.Home.PageActions");

  void set(Key key, List<Widget>? actions) {
    if (actions == null) {
      _map.remove(key);
    } else {
      _map[key] = actions;
    }
    log.finest(() => "notify PageActions->set()");
    notifyListeners();
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  final Logger log = Logger("Pages.Home.Page");

  int _index = 0;
  late Widget _newTransactionFab;

  final PageActions _actions = PageActions();

  // Page keys – preserved from original code.
  static const Key _keyOverview = Key("HomeOverview");
  static const Key _keyBanks = Key("HomeBanks");
  static const Key _keyCards = Key("HomeCards");
  static const Key _keySavings = Key("HomeSavings");
  static const Key _keyMortgage = Key("HomeMortgage");

  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();

    _pages = <Widget>[
      HomeOverview(
        key: _keyOverview,
        onNavigateToCards: () => _onSelect(2),
      ),
      const HomeBanks(key: _keyBanks),
      const HomeCards(key: _keyCards),
      const HomeSavings(key: _keySavings),
      const HomeMortgage(key: _keyMortgage),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _newTransactionFab = NewTransactionFab(context: context);
      _publishElements();
    });

    _actions.addListener(_publishElements);
  }

  @override
  void dispose() {
    _actions.removeListener(_publishElements);
    super.dispose();
  }

  /// Publishes FAB, appBarActions and bottomNav into [NavPageElements].
  void _publishElements() {
    if (!mounted) return;
    log.finer(() => "_publishElements(index: $_index)");

    final NavPageElements nav = context.read<NavPageElements>();

    // FAB only on Overview (index 0).
    nav.fab = (_index == 0) ? _newTransactionFab : null;

    // Theme toggle – first action on every tab. Uses a Builder so that
    // Theme.of(context).brightness reflects the current effective brightness
    // and rebuilds whenever the theme changes.
    final Widget themeToggle = Builder(
      builder: (BuildContext ctx) {
        final Brightness brightness = Theme.of(ctx).brightness;
        final bool isDark = brightness == Brightness.dark;
        return IconButton(
          icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
          tooltip: S.of(ctx).themeToggleTooltip,
          onPressed: () {
            context.read<SettingsProvider>().setTheme(
              isDark ? ThemeMode.light : ThemeMode.dark,
            );
          },
        );
      },
    );

    // App-bar actions: theme toggle first, then per-page actions.
    final List<Widget> pageActions =
        _actions.get(_pages[_index].key ?? const Key('')) ?? <Widget>[];
    nav.appBarActions = <Widget>[themeToggle, ...pageActions];

    // Bottom nav.
    nav.bottomNav = VaultBottomNav(
      currentIndex: _index,
      onSelect: _onSelect,
    );
  }

  void _onSelect(int i) {
    if (i == _index) return;
    setState(() {
      _index = i;
    });
    // Publish after setState so _index is updated.
    WidgetsBinding.instance.addPostFrameCallback((_) => _publishElements());
  }

  @override
  Widget build(BuildContext context) {
    log.finest(() => "build(index: $_index)");

    // Publish bottom nav / appBarActions on every build so the bar reflects
    // the current index without needing a separate listener call.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publishElements();
    });

    return ChangeNotifierProvider<PageActions>.value(
      value: _actions,
      child: IndexedStack(
        index: _index,
        children: _pages,
      ),
    );
  }
}
