import 'package:chopper/chopper.dart' show Response;
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';
import 'package:waterflyiii/pages/home/banks.dart';
import 'package:waterflyiii/pages/home/cards.dart';
import 'package:waterflyiii/pages/home/overview.dart';
import 'package:waterflyiii/pages/home/budget.dart';
import 'package:waterflyiii/pages/home/savings.dart';
import 'package:waterflyiii/pages/navigation.dart';
import 'package:waterflyiii/settings.dart';
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

  /// Display name derived from the user's email local-part (e.g. "Amit").
  /// Null while loading; empty string on error / no usable segment.
  String? _displayName;

  final PageActions _actions = PageActions();

  // Page keys – preserved from original code.
  static const Key _keyOverview = Key("HomeOverview");
  static const Key _keyBanks = Key("HomeBanks");
  static const Key _keyCards = Key("HomeCards");
  static const Key _keySavings = Key("HomeSavings");
  static const Key _keyBudget = Key("HomeBudget");

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
      const HomeBudget(key: _keyBudget),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _publishElements();
      _fetchUserName();
    });

    _actions.addListener(_publishElements);
  }

  /// Fetches the current user's email via [v1AboutUserGet] and derives a
  /// display name from the local part.  Updates state once, then re-publishes
  /// the app-bar title.  All errors are silently swallowed — the greeting
  /// falls back to single-line mode when [_displayName] remains null or empty.
  Future<void> _fetchUserName() async {
    try {
      final FireflyIii api = context.read<FireflyService>().api;
      final Response<UserSingle> response =
          await api.v1AboutUserGet();
      if (!mounted) return;

      final String? email = response.body?.data.attributes.email;
      if (email != null && email.isNotEmpty) {
        // Local part = everything before the first '@'.
        final String localPart = email.split('@').first;
        // Split on '.', '_', or '-' and take the first non-empty segment.
        final List<String> segments =
            localPart.split(RegExp(r'[._\-]'));
        final String first =
            segments.firstWhere((String s) => s.isNotEmpty, orElse: () => '');
        if (first.isNotEmpty) {
          setState(() {
            _displayName =
                first[0].toUpperCase() + first.substring(1).toLowerCase();
          });
        } else {
          setState(() => _displayName = '');
        }
      } else {
        setState(() => _displayName = '');
      }
    } catch (_) {
      if (mounted) setState(() => _displayName = '');
    }
    // Re-publish so the app bar picks up the name.
    if (mounted) _publishElements();
  }

  /// Returns the appropriate greeting string for the current local time.
  String _greeting(BuildContext ctx) {
    final int hour = DateTime.now().hour;
    final S s = S.of(ctx);
    if (hour < 12) return s.greetingMorning;
    if (hour < 17) return s.greetingAfternoon;
    return s.greetingEvening;
  }

  /// Builds the two-line (or one-line fallback) greeting widget for the
  /// app bar title.
  Widget _buildGreetingTitle(BuildContext ctx) {
    final String greeting = _greeting(ctx);
    final TextTheme tt = Theme.of(ctx).textTheme;
    final ColorScheme cs = Theme.of(ctx).colorScheme;

    // Name is known and non-empty → two-line layout.
    final String? name = _displayName;
    if (name != null && name.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            greeting,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          Text(
            name,
            style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      );
    }

    // Fallback: single greeting line at titleLarge.
    return Text(
      greeting,
      style: tt.titleLarge,
    );
  }

  @override
  void dispose() {
    _actions.removeListener(_publishElements);
    super.dispose();
  }

  /// Publishes appBarTitle, appBarActions and bottomNav into [NavPageElements].
  void _publishElements() {
    if (!mounted) return;
    log.finer(() => "_publishElements(index: $_index)");

    final NavPageElements nav = context.read<NavPageElements>();

    // No FAB on home tabs.
    nav.fab = null;

    // Greeting title — use a Builder so Theme.of(context) is correct.
    nav.appBarTitle = Builder(
      builder: (BuildContext ctx) => _buildGreetingTitle(ctx),
    );

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
