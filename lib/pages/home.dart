import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/pages/home/analyze.dart';
import 'package:waterflyiii/pages/home/banks.dart';
import 'package:waterflyiii/pages/home/cards.dart';
import 'package:waterflyiii/pages/home/overview.dart';
import 'package:waterflyiii/pages/home/mortgage.dart';
import 'package:waterflyiii/pages/home/savings.dart';
import 'package:waterflyiii/pages/navigation.dart';
import 'package:waterflyiii/widgets/fabs.dart';

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

class HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  final Logger log = Logger("Pages.Home.Page");

  late TabController _tabController;
  late Widget _newTransactionFab;

  final PageActions _actions = PageActions();

  // AI tab is at index 5
  static const int _aiTabIndex = 5;

  @override
  void initState() {
    super.initState();

    _tabController = TabController(vsync: this, length: 6);
    _tabController.addListener(_handleTabChange);

    tabPages = <Widget>[
      HomeOverview(
        key: const Key("HomeOverview"),
        onNavigateToCards: () => _tabController.animateTo(2),
      ),
      const HomeBanks(key: Key("HomeBanks")),
      const HomeCards(key: Key("HomeCards")),
      const HomeSavings(key: Key("HomeSavings")),
      const HomeMortgage(key: Key("HomeMortgage")),
      const HomeAnalyze(key: Key("HomeAnalyze")),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _newTransactionFab = NewTransactionFab(context: context);
      // TabBar is set in build() so it updates when hasGeminiKey changes
      _handleTabChange();
    });

    _actions.addListener(() => _handleTabChange());
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();

    super.dispose();
  }

  void _handleTabChange() {
    if (!_tabController.indexIsChanging) {
      log.finer(() => "_handleTabChange(${_tabController.index})");
      final bool hasGeminiKey = context.read<FireflyService>().hasGeminiKey;
      if (_tabController.index == _aiTabIndex && !hasGeminiKey) {
        final int previous = _tabController.previousIndex;
        _tabController.animateTo(previous == _aiTabIndex ? 0 : previous);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(S.of(context).analyzeAddGeminiKeyInSettings),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      // FAB only on Overview tab (index 0)
      context.read<NavPageElements>().fab =
          (_tabController.index == 0) ? _newTransactionFab : null;
      context.read<NavPageElements>().appBarActions = _actions.get(
        tabPages[_tabController.index].key ?? const Key(''),
      );
    }
  }

  late List<Tab> tabs;

  late final List<Widget> tabPages;

  @override
  Widget build(BuildContext context) {
    log.finest(() => "build(tab: ${_tabController.index})");
    final bool hasGeminiKey = context.watch<FireflyService>().hasGeminiKey;
    final S l10n = S.of(context);
    final TabBar tabBar = TabBar(
      isScrollable: true,
      controller: _tabController,
      tabs: <Tab>[
        Tab(text: l10n.homeTabLabelOverview),
        Tab(text: l10n.homeTabLabelBanks),
        Tab(text: l10n.homeTabLabelCards),
        Tab(text: l10n.homeTabLabelSavings),
        Tab(text: l10n.homeTabLabelMortgage),
        Tab(
          child: hasGeminiKey
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Image.asset(
                      'assets/images/ai_tab_icon.png',
                      width: 22,
                      height: 22,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(width: 6),
                    Text(l10n.homeTabLabelAnalyze),
                  ],
                )
              : Opacity(
                  opacity: 0.5,
                  child: IgnorePointer(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Image.asset(
                          'assets/images/ai_tab_icon.png',
                          width: 22,
                          height: 22,
                          fit: BoxFit.contain,
                        ),
                        const SizedBox(width: 6),
                        Text(l10n.homeTabLabelAnalyze),
                        const SizedBox(width: 4),
                        Icon(Icons.lock_outline, size: 14, color: Theme.of(context).colorScheme.onSurface),
                      ],
                    ),
                  ),
                ),
        ),
      ],
      tabAlignment: TabAlignment.start,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      context.read<NavPageElements>().appBarBottom = tabBar;
    });
    return ChangeNotifierProvider<PageActions>.value(
      value: _actions,
      child: TabBarView(controller: _tabController, children: tabPages),
    );
  }
}
