import 'package:flutter/material.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/theme.dart';

/// Custom raised bottom navigation bar for the Home destination.
///
/// Visual order left→right: Banks · Cards · [RAISED CENTER = Overview] · Savings · Budget
///
/// Index mapping (matches [HomePageState._index]):
///   0 = Overview (center raised button)
///   1 = Banks
///   2 = Cards
///   3 = Savings
///   4 = Budget
class VaultBottomNav extends StatelessWidget {
  const VaultBottomNav({
    super.key,
    required this.currentIndex,
    required this.onSelect,
  });

  final int currentIndex;
  final void Function(int) onSelect;

  // Height of the flat bar, excluding bottom safe-area inset.
  static const double barHeight = 82.0;

  // Diameter of the raised center circle.
  static const double _centerDiameter = 60.0;

  // Half the circle diameter: how many pixels protrude above the bar.
  static const double _centerProtrusion = _centerDiameter / 2; // 30 px

  // Top-of-bar padding for side items (per mockup).
  static const double _itemTopPadding = 14.0;

  // Icon size for side items.
  static const double _iconSize = 22.0;

  // Ring around circle implemented via BoxShadow spread.
  static const double _ringSpread = 6.0;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final Color scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
    final double bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
    final S l10n = S.of(context);

    // Total widget height = protrusion headroom + bar + safe area.
    // The outer SizedBox MUST contain the entire circle so hit-testing works —
    // we do NOT rely on Clip.none overflow for tap targets.
    final double totalHeight = _centerProtrusion + barHeight + bottomPadding;

    return SizedBox(
      height: totalHeight,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomCenter,
        children: <Widget>[
          // ── Flat bar ────────────────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: barHeight + bottomPadding,
              decoration: BoxDecoration(
                color: colorScheme.surface,
                border: Border(
                  top: BorderSide(color: colorScheme.outline),
                ),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(26),
                ),
              ),
              child: Padding(
                padding: EdgeInsets.only(bottom: bottomPadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const SizedBox(height: _itemTopPadding),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _SideNavItem(
                          icon: Icons.account_balance_outlined,
                          selectedIcon: Icons.account_balance,
                          label: l10n.homeTabLabelBanks,
                          selected: currentIndex == 1,
                          onTap: () => onSelect(1),
                        ),
                        _SideNavItem(
                          icon: Icons.credit_card_outlined,
                          selectedIcon: Icons.credit_card,
                          label: l10n.homeTabLabelCards,
                          selected: currentIndex == 2,
                          onTap: () => onSelect(2),
                        ),
                        // Gap for the raised center button.
                        const SizedBox(width: _centerDiameter + 8),
                        _SideNavItem(
                          icon: Icons.savings_outlined,
                          selectedIcon: Icons.savings,
                          label: l10n.homeTabLabelSavings,
                          selected: currentIndex == 3,
                          onTap: () => onSelect(3),
                        ),
                        _SideNavItem(
                          icon: Icons.pie_chart_outline,
                          selectedIcon: Icons.pie_chart,
                          label: l10n.homeTabLabelBudget,
                          selected: currentIndex == 4,
                          onTap: () => onSelect(4),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Raised center (Overview) ─────────────────────────────────────────
          // Anchor the column's TOP at the widget top (top: 0). The bar's top
          // edge is at totalHeight - (barHeight + bottomPadding)
          // = _centerProtrusion (30 px) from the widget top. The circle is the
          // column's first child spanning y = 0.._centerDiameter (0..60), so
          // its center lands at y = 30 — exactly on the bar's top edge (30 px
          // above, 30 px inside). The label (y ≈ 64..78) sits inside the bar
          // directly under the circle. Horizontal centering comes from the
          // Stack's alignment (Alignment.bottomCenter) applying to the unset
          // horizontal axis.
          Positioned(
            top: 0,
            child: _RaisedCenterButton(
              selected: currentIndex == 0,
              onTap: () => onSelect(0),
              label: l10n.homeTabLabelOverview,
              scaffoldBg: scaffoldBg,
              colorScheme: colorScheme,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Side navigation item ────────────────────────────────────────────────────

class _SideNavItem extends StatelessWidget {
  const _SideNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final Color color =
        selected ? colorScheme.primary : colorScheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 28,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                selected ? selectedIcon : icon,
                color: color,
                size: VaultBottomNav._iconSize,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight:
                      selected ? FontWeight.w600 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Raised center button ────────────────────────────────────────────────────

class _RaisedCenterButton extends StatelessWidget {
  const _RaisedCenterButton({
    required this.selected,
    required this.onTap,
    required this.label,
    required this.scaffoldBg,
    required this.colorScheme,
  });

  final bool selected;
  final VoidCallback onTap;
  final String label;
  final Color scaffoldBg;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final MoneyColors moneyColors = Theme.of(context).extension<MoneyColors>()!;

    // The column's bottom is pinned to Positioned.bottom, so the column
    // extends upward. We want the circle's center at Positioned.bottom, meaning
    // the circle's bottom edge is at Positioned.bottom - _centerDiameter/2.
    // In a column the circle is the first child (top), label below.
    // Positioned.bottom = barHeight + bottomPadding anchors the circle center
    // on the bar top. The label sits inside the bar.
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: VaultBottomNav._centerDiameter / 2 + VaultBottomNav._ringSpread,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: VaultBottomNav._centerDiameter,
              height: VaultBottomNav._centerDiameter,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: moneyColors.heroGradient,
                  center: Alignment.topCenter,
                  radius: 1.2,
                ),
                boxShadow: <BoxShadow>[
                  // Cut-out ring: scaffold background color, zero blur,
                  // spread = _ringSpread, rendered UNDER the glow shadow
                  // so the circle looks punched through the bar.
                  BoxShadow(
                    color: scaffoldBg,
                    blurRadius: 0,
                    spreadRadius: VaultBottomNav._ringSpread,
                  ),
                  BoxShadow(
                    color: colorScheme.primary.withAlpha(0x55),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
                border: selected
                    ? Border.all(
                        color: colorScheme.primary.withAlpha(0xCC),
                        width: 2,
                      )
                    : null,
              ),
              child: Icon(
                Icons.account_balance_wallet,
                color: colorScheme.onPrimary,
                size: 26,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: moneyColors.goldDeep,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
