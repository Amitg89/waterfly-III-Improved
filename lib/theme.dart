import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// MoneyColors – ThemeExtension that exposes money-semantic colors app-wide.
// Retrieve with: Theme.of(context).extension<MoneyColors>()!
// ---------------------------------------------------------------------------
class MoneyColors extends ThemeExtension<MoneyColors> {
  const MoneyColors({
    required this.positive,
    required this.negative,
    required this.goldDeep,
    required this.cardGradients,
    required this.heroGradient,
    required this.heroForeground,
    required this.cardFaceForeground,
  });

  /// Emerald – money-in, positive balance
  final Color positive;

  /// Clay – money-out, negative balance
  final Color negative;

  /// Deep gold – secondary accents, links on dark backgrounds
  final Color goldDeep;

  /// Three two-stop gradients for credit-card face backgrounds (always dark).
  /// [dark bronze, emerald, plum]
  final List<List<Color>> cardGradients;

  /// Gold hero gradient [start, mid, end]
  final List<Color> heroGradient;

  /// Espresso dark – always dark regardless of theme, for text on the gold
  /// hero card (onPrimary flips between themes; this stays espresso always).
  final Color heroForeground;

  /// Cream light – always light, for text on dark card faces in the carousel.
  final Color cardFaceForeground;

  // ---- ThemeExtension boilerplate ----------------------------------------

  @override
  MoneyColors copyWith({
    Color? positive,
    Color? negative,
    Color? goldDeep,
    List<List<Color>>? cardGradients,
    List<Color>? heroGradient,
    Color? heroForeground,
    Color? cardFaceForeground,
  }) {
    return MoneyColors(
      positive: positive ?? this.positive,
      negative: negative ?? this.negative,
      goldDeep: goldDeep ?? this.goldDeep,
      cardGradients: cardGradients ?? this.cardGradients,
      heroGradient: heroGradient ?? this.heroGradient,
      heroForeground: heroForeground ?? this.heroForeground,
      cardFaceForeground: cardFaceForeground ?? this.cardFaceForeground,
    );
  }

  @override
  MoneyColors lerp(ThemeExtension<MoneyColors>? other, double t) {
    if (other is! MoneyColors) return this;
    return MoneyColors(
      positive: Color.lerp(positive, other.positive, t)!,
      negative: Color.lerp(negative, other.negative, t)!,
      goldDeep: Color.lerp(goldDeep, other.goldDeep, t)!,
      cardGradients: List<List<Color>>.generate(
        cardGradients.length,
        (int i) {
          final List<Color> a = cardGradients[i];
          final List<Color> b =
              i < other.cardGradients.length ? other.cardGradients[i] : a;
          return List<Color>.generate(
            a.length,
            (int j) => Color.lerp(a[j], j < b.length ? b[j] : a[j], t)!,
          );
        },
      ),
      heroGradient: List<Color>.generate(
        heroGradient.length,
        (int i) => Color.lerp(
          heroGradient[i],
          i < other.heroGradient.length ? other.heroGradient[i] : heroGradient[i],
          t,
        )!,
      ),
      heroForeground: Color.lerp(heroForeground, other.heroForeground, t)!,
      cardFaceForeground: Color.lerp(cardFaceForeground, other.cardFaceForeground, t)!,
    );
  }
}

// ---------------------------------------------------------------------------
// Shared card gradients (always dark, same in both themes).
// ---------------------------------------------------------------------------
const List<List<Color>> _cardGradients = <List<Color>>[
  <Color>[Color(0xFF3F2D1B), Color(0xFF7C531F)], // dark bronze
  <Color>[Color(0xFF1F3A30), Color(0xFF0F5340)], // emerald
  <Color>[Color(0xFF3A2233), Color(0xFF6D2A45)], // plum
];

// ---------------------------------------------------------------------------
// DARK MoneyColors
// ---------------------------------------------------------------------------
const MoneyColors _darkMoneyColors = MoneyColors(
  positive: Color(0xFF54B889),
  negative: Color(0xFFDE6E4C),
  goldDeep: Color(0xFFC97F2C),
  cardGradients: _cardGradients,
  heroGradient: <Color>[Color(0xFFC97F2C), Color(0xFFE7B04A), Color(0xFF8A531D)],
  // Espresso dark – stays espresso in both themes for text on the gold hero.
  heroForeground: Color(0xFF2A1B0B),
  // Warm cream – stays cream in both themes for text on dark card faces.
  cardFaceForeground: Color(0xFFF6EEDD),
);

// ---------------------------------------------------------------------------
// LIGHT MoneyColors
// ---------------------------------------------------------------------------
const MoneyColors _lightMoneyColors = MoneyColors(
  positive: Color(0xFF2E9E6B),
  negative: Color(0xFFC85A38),
  goldDeep: Color(0xFFA9631E),
  cardGradients: _cardGradients,
  heroGradient: <Color>[Color(0xFFC97F2C), Color(0xFFE7B04A), Color(0xFF8A531D)],
  // Espresso dark – same as dark theme; onPrimary in light is cream so we
  // cannot rely on it for text on the gold hero card.
  heroForeground: Color(0xFF2A1B0B),
  // Warm cream – same in both themes.
  cardFaceForeground: Color(0xFFF6EEDD),
);

// ---------------------------------------------------------------------------
// Internal helper – shared component-theme setup.
// ---------------------------------------------------------------------------
ThemeData _buildVaultTheme({
  required ColorScheme colorScheme,
  required Color scaffoldBackground,
}) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: scaffoldBackground,
    extensions: <ThemeExtension<dynamic>>[
      colorScheme.brightness == Brightness.dark
          ? _darkMoneyColors
          : _lightMoneyColors,
    ],
    // Cards
    cardTheme: CardThemeData(
      color: colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    // Bottom sheet
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
    ),
    // App bar – transparent, no shadow. RoundedRectangleBorder workaround for
    // https://github.com/flutter/flutter/issues/131042#issuecomment-1690737834
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: const RoundedRectangleBorder(),
      foregroundColor: colorScheme.onSurface,
    ),
    // Dividers use the scheme outline (already has low alpha gold baked in)
    dividerTheme: DividerThemeData(color: colorScheme.outline),
    // Navigation bar
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colorScheme.surface,
      indicatorColor: colorScheme.primary.withAlpha(0x33),
    ),
    // Page transitions – keep predictive back for Android
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// PUBLIC API
// ---------------------------------------------------------------------------

/// Dark "Vault" theme: deep espresso background, brushed-gold accent.
ThemeData vaultDark() {
  const ColorScheme scheme = ColorScheme(
    brightness: Brightness.dark,
    // Primary – gold
    primary: Color(0xFFE7B04A),
    onPrimary: Color(0xFF2A1B0B),
    primaryContainer: Color(0xFF5A3A0F),
    onPrimaryContainer: Color(0xFFFFE0A3),
    // Secondary – deeper gold
    secondary: Color(0xFFC97F2C),
    onSecondary: Color(0xFF2A1B0B),
    secondaryContainer: Color(0xFF4A2E0A),
    onSecondaryContainer: Color(0xFFFFD49A),
    // Tertiary – muted warm
    tertiary: Color(0xFFA6968A),
    onTertiary: Color(0xFF1B1410),
    tertiaryContainer: Color(0xFF33251D),
    onTertiaryContainer: Color(0xFFF3E9DA),
    // Error – warm red
    error: Color(0xFFE2664A),
    onError: Color(0xFF2A1B0B),
    errorContainer: Color(0xFF5C1C0A),
    onErrorContainer: Color(0xFFFFDAD3),
    // Surfaces
    surface: Color(0xFF2B201A),
    onSurface: Color(0xFFF3E9DA),
    surfaceContainerHighest: Color(0xFF33251D),
    onSurfaceVariant: Color(0xFFA6968A),
    // Outline – gold at low alpha
    outline: Color(0x24E7B04A),
    outlineVariant: Color(0x40E7B04A),
    // Scaffold / background (set separately via scaffoldBackgroundColor)
    surfaceContainerHigh: Color(0xFF33251D),
    surfaceContainerLow: Color(0xFF231811),
    surfaceContainer: Color(0xFF2B201A),
    surfaceDim: Color(0xFF1B1410),
    surfaceBright: Color(0xFF3D2E24),
    inverseSurface: Color(0xFFF3E9DA),
    onInverseSurface: Color(0xFF2B201A),
    inversePrimary: Color(0xFF8A531D),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  return _buildVaultTheme(
    colorScheme: scheme,
    scaffoldBackground: const Color(0xFF1B1410),
  );
}

/// Light "Vault" theme: warm sand background, deeper gold for contrast.
ThemeData vaultLight() {
  const ColorScheme scheme = ColorScheme(
    brightness: Brightness.light,
    // Primary – deeper gold (for contrast on light)
    primary: Color(0xFFC97F2C),
    onPrimary: Color(0xFFFFF7EA),
    primaryContainer: Color(0xFFFFE0A3),
    onPrimaryContainer: Color(0xFF3D1F00),
    // Secondary – even deeper gold
    secondary: Color(0xFFA9631E),
    onSecondary: Color(0xFFFFF7EA),
    secondaryContainer: Color(0xFFFFD49A),
    onSecondaryContainer: Color(0xFF3D1F00),
    // Tertiary – muted warm
    tertiary: Color(0xFF8B7660),
    onTertiary: Color(0xFFFFF7EA),
    tertiaryContainer: Color(0xFFF5EBD9),
    onTertiaryContainer: Color(0xFF2B1E12),
    // Error – warm red
    error: Color(0xFFE2664A),
    onError: Color(0xFFFFF7EA),
    errorContainer: Color(0xFFFFDAD3),
    onErrorContainer: Color(0xFF5C1C0A),
    // Surfaces
    surface: Color(0xFFFFFCF6),
    onSurface: Color(0xFF2B1E12),
    surfaceContainerHighest: Color(0xFFF5EBD9),
    onSurfaceVariant: Color(0xFF8B7660),
    // Outline – gold at low alpha
    outline: Color(0x33C97F2C),
    outlineVariant: Color(0x55C97F2C),
    // Surface containers
    surfaceContainerHigh: Color(0xFFF5EBD9),
    surfaceContainerLow: Color(0xFFF7EFE1),
    surfaceContainer: Color(0xFFFFFCF6),
    surfaceDim: Color(0xFFE8D8C4),
    surfaceBright: Color(0xFFFFFCF6),
    inverseSurface: Color(0xFF2B1E12),
    onInverseSurface: Color(0xFFFFFCF6),
    inversePrimary: Color(0xFFE7B04A),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  return _buildVaultTheme(
    colorScheme: scheme,
    scaffoldBackground: const Color(0xFFF1E6D4),
  );
}

/// Attaches [MoneyColors] from the vault palette onto an existing [ThemeData].
/// Used in the dynamic-color branch so `extension<MoneyColors>()` is never null.
ThemeData withVaultMoneyColors(ThemeData base) {
  final MoneyColors mc = base.brightness == Brightness.dark
      ? _darkMoneyColors
      : _lightMoneyColors;
  return base.copyWith(
    extensions: <ThemeExtension<Object?>>[
      ...base.extensions.values.cast<ThemeExtension<Object?>>(),
      mc,
    ],
  );
}
