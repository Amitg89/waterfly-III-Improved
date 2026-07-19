import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/pages/home/analyze.dart';
import 'package:waterflyiii/settings.dart';
import 'package:waterflyiii/theme.dart';
import 'package:waterflyiii/widgets/vault_bottom_nav.dart';

final Logger log = Logger("Widgets.AiBubble");

/// Draggable, dismissible floating "Ask AI" bubble.
///
/// Must be placed as a direct child of a [Stack] (it expands via
/// [Positioned.fill] and positions itself inside). Position and visibility
/// are persisted through [SettingsProvider]; tapping opens a floating
/// messenger-style AI panel (with a Gemini-key guard); tapping the small
/// badge hides the bubble.
class AiBubble extends StatefulWidget {
  const AiBubble({super.key});

  @override
  State<AiBubble> createState() => _AiBubbleState();
}

class _AiBubbleState extends State<AiBubble> {
  static const double _bubbleSize = 56;
  static const double _badgeSize = 20;
  // Bubble + badge overhang footprint (badge overlaps the top-right corner).
  static const double _headSize = 62;
  // Estimated total height incl. the "Ask AI" tag below the bubble.
  static const double _totalHeight = 84;
  static const double _edgeMargin = 8;
  // Default placement: above the new-transaction FAB.
  static const double _defaultBottomOffset = 190;

  /// Whether the floating AI panel is currently shown.
  bool _panelOpen = false;

  /// Local position while (and after) dragging; null = follow provider.
  Offset? _dragPosition;

  /// Whether the current gesture has moved enough to be treated as a drag.
  /// Used to suppress the onTap callback after a successful pan.
  bool _isDragging = false;

  Offset _resolvePosition(
    SettingsProvider settings,
    BoxConstraints constraints,
    TextDirection direction,
  ) {
    double x = _dragPosition?.dx ?? settings.aiBubbleX;
    double y = _dragPosition?.dy ?? settings.aiBubbleY;

    if (x == SettingsProvider.aiBubblePositionUnset ||
        y == SettingsProvider.aiBubblePositionUnset) {
      // Default: end side, above the new-transaction FAB.
      x = direction == TextDirection.rtl
          ? 16
          : constraints.maxWidth - _headSize - 16;
      y = constraints.maxHeight -
          MediaQuery.viewPaddingOf(context).bottom -
          VaultBottomNav.barHeight -
          _defaultBottomOffset;
    }

    // Clamp within safe bounds on every build so rotation/resize never
    // loses the bubble.
    final double maxX = constraints.maxWidth - _headSize - _edgeMargin;
    final double maxY = constraints.maxHeight -
        MediaQuery.viewPaddingOf(context).bottom -
        _totalHeight -
        _edgeMargin;
    x = x.clamp(_edgeMargin, maxX < _edgeMargin ? _edgeMargin : maxX);
    y = y.clamp(_edgeMargin, maxY < _edgeMargin ? _edgeMargin : maxY);

    return Offset(x, y);
  }

  void _onBubbleTap(BuildContext context) {
    final bool hasGeminiKey = context.read<FireflyService>().hasGeminiKey;
    if (!hasGeminiKey) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(S.of(context).analyzeAddGeminiKeyInSettings),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() {
      _panelOpen = true;
    });
  }

  void _closePanel() {
    setState(() {
      _panelOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final MoneyColors moneyColors = Theme.of(context).extension<MoneyColors>()!;
    final TextDirection direction = Directionality.of(context);

    // If visibility is turned off externally while panel is open, close it.
    if (!settings.aiBubbleVisible && _panelOpen) {
      // Schedule post-frame to avoid setState during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _panelOpen) {
          setState(() {
            _panelOpen = false;
          });
        }
      });
    }

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Offset pos =
              _resolvePosition(settings, constraints, direction);

          // Bottom offset for the panel: above bottom nav + safe area + 8 px.
          final double bottomSafeArea =
              MediaQuery.viewPaddingOf(context).bottom;
          final double panelBottom =
              VaultBottomNav.barHeight + bottomSafeArea + 8;

          // Panel height: ~62 % of available body height, clamped sensibly.
          final double availableHeight =
              constraints.maxHeight - panelBottom - 12;
          final double panelHeight =
              (availableHeight * 0.62).clamp(220, availableHeight);

          return Stack(
            children: <Widget>[
              // ── Floating bubble ─────────────────────────────────────────────
              // Hidden while the panel is open.
              if (!_panelOpen)
                Positioned(
                  left: pos.dx,
                  top: pos.dy,
                  // ONE unified GestureDetector handles both tap (open panel)
                  // and pan (drag bubble).
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (!_isDragging) {
                        _onBubbleTap(context);
                      }
                    },
                    onPanStart: (DragStartDetails details) {
                      setState(() {
                        _isDragging = false;
                        _dragPosition ??= pos;
                      });
                    },
                    onPanUpdate: (DragUpdateDetails details) {
                      setState(() {
                        _isDragging = true;
                        _dragPosition =
                            (_dragPosition ?? pos) + details.delta;
                      });
                    },
                    onPanEnd: (DragEndDetails details) {
                      // Re-resolve to apply clamping before persisting.
                      final Offset end = _resolvePosition(
                        settings,
                        constraints,
                        direction,
                      );
                      settings.setAiBubblePosition(end.dx, end.dy);
                      setState(() {
                        _isDragging = false;
                      });
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        SizedBox(
                          width: _headSize,
                          height: _headSize,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: <Widget>[
                              PositionedDirectional(
                                start: 0,
                                bottom: 0,
                                child: Container(
                                  width: _bubbleSize,
                                  height: _bubbleSize,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      center: const Alignment(-0.5, -0.5),
                                      radius: 1.2,
                                      colors: <Color>[
                                        moneyColors.heroGradient[1],
                                        moneyColors.heroGradient[0],
                                        moneyColors.heroGradient[2],
                                      ],
                                    ),
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(
                                        color: colorScheme.primary
                                            .withAlpha(0x66),
                                        blurRadius: 20,
                                        offset: const Offset(0, 8),
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    Icons.auto_awesome,
                                    color: colorScheme.onPrimary,
                                    size: 26,
                                  ),
                                ),
                              ),
                              PositionedDirectional(
                                end: 0,
                                top: 0,
                                // The ✕ badge keeps its own GestureDetector
                                // with onTap only (no pan). Because it is a
                                // *deeper* hit-test member than the outer
                                // GestureDetector, Flutter's hit-test walk
                                // visits it first. Its TapGestureRecognizer
                                // is added to the gesture arena before the
                                // outer recognizers, giving it priority.
                                child: GestureDetector(
                                  onTap: () =>
                                      settings.setAiBubbleVisible(false),
                                  child: Container(
                                    width: _badgeSize,
                                    height: _badgeSize,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: colorScheme
                                          .surfaceContainerHighest,
                                      border: Border.all(
                                        color: colorScheme.outline,
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.close,
                                      size: 12,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          S.of(context).aiBubbleTag,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: moneyColors.goldDeep,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),

              // ── Floating AI panel ────────────────────────────────────────────
              // Shown in place of the bubble; no barrier so the rest of the
              // app stays tappable. ExcludeSemantics is not used — the panel
              // itself has proper semantics.
              if (_panelOpen)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: panelBottom,
                  height: panelHeight,
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: colorScheme.outline,
                          width: 0.5,
                        ),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: colorScheme.primary.withAlpha(0x33),
                            blurRadius: 24,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            // ── Panel header ────────────────────────────────
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Row(
                                children: <Widget>[
                                  // 28 px gold gradient circle with star icon.
                                  Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: LinearGradient(
                                        colors: moneyColors.heroGradient,
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.auto_awesome,
                                      color: colorScheme.onPrimary,
                                      size: 16,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    S.of(context).aiBubbleTag,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  const Spacer(),
                                  // Minimize button — returns to the bubble.
                                  IconButton(
                                    icon: const Icon(
                                      Icons.close_fullscreen,
                                    ),
                                    tooltip: S.of(context).aiBubbleTag,
                                    onPressed: _closePanel,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              ),
                            ),
                            Divider(
                              height: 1,
                              thickness: 0.5,
                              color: colorScheme.outline,
                            ),
                            // ── Panel body: HomeAnalyze ─────────────────────
                            const Expanded(
                              child: HomeAnalyze(
                                key: Key("HomeAnalyzePanel"),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
