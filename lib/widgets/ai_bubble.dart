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
/// are persisted through [SettingsProvider]; tapping opens the AI analyze
/// page (with a Gemini-key guard), tapping the small badge hides the bubble.
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

  void _openAiPage(BuildContext context) {
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

    // HomeAnalyze reads FireflyService & SettingsProvider from the app root.
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext ctx) => Scaffold(
          appBar: AppBar(
            title: Text(S.of(ctx).homeTabLabelAnalyze),
          ),
          body: const HomeAnalyze(key: Key("HomeAnalyzeRoute")),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final MoneyColors moneyColors = Theme.of(context).extension<MoneyColors>()!;
    final TextDirection direction = Directionality.of(context);

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Offset pos =
              _resolvePosition(settings, constraints, direction);

          return Stack(
            children: <Widget>[
              Positioned(
                left: pos.dx,
                top: pos.dy,
                // ONE unified GestureDetector handles both tap (open AI page)
                // and pan (drag bubble). HitTestBehavior.opaque ensures the
                // full column area (including transparent gaps between widgets)
                // participates in hit-testing, so slow precise swipes that land
                // anywhere on the column are captured correctly.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    // Only fire if this gesture was not a drag.
                    if (!_isDragging) {
                      _openAiPage(context);
                    }
                  },
                  onPanStart: (DragStartDetails details) {
                    // Seed _dragPosition from the already-resolved position
                    // stored in state (_dragPosition) rather than from the
                    // build-captured `pos` variable. This avoids the stale-
                    // closure bug where multiple onPanUpdate calls within a
                    // single frame would each add their delta to the same old
                    // `pos` value, compounding incorrectly.
                    setState(() {
                      _isDragging = false;
                      _dragPosition ??= pos;
                    });
                  },
                  onPanUpdate: (DragUpdateDetails details) {
                    setState(() {
                      _isDragging = true;
                      // Accumulate purely against _dragPosition (state), not
                      // against the build-captured `pos`. If multiple updates
                      // arrive before the next frame, each correctly builds on
                      // the previous accumulated value rather than re-basing on
                      // a stale snapshot.
                      _dragPosition = (_dragPosition ?? pos) + details.delta;
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
                              // The bubble circle itself has no separate tap
                              // handler — taps bubble up to the outer
                              // GestureDetector's onTap, which calls
                              // _openAiPage. No nested tap recognizer means no
                              // arena conflict with the outer pan recognizer.
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
                              // The ✕ badge keeps its own GestureDetector with
                              // onTap only (no pan). Because it is a *deeper*
                              // hit-test member than the outer GestureDetector,
                              // Flutter's hit-test walk visits it first. Its
                              // TapGestureRecognizer is added to the gesture
                              // arena before the outer recognizers, giving it
                              // priority: when the pointer is released without
                              // moving, the inner tap wins and setAiBubbleVisible
                              // fires; the outer onTap is NOT called because the
                              // inner recognizer claims the pointer. Drags on the
                              // badge area still propagate to the outer pan
                              // recognizer because the inner detector has no pan
                              // handler and therefore never claims pointer
                              // ownership for pan gestures.
                              child: GestureDetector(
                                onTap: () =>
                                    settings.setAiBubbleVisible(false),
                                child: Container(
                                  width: _badgeSize,
                                  height: _badgeSize,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color:
                                        colorScheme.surfaceContainerHighest,
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
            ],
          );
        },
      ),
    );
  }
}
