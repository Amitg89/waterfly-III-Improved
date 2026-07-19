import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' as intl;
import 'package:provider/provider.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/stock.dart';
import 'dart:math' as math;

import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';
import 'package:waterflyiii/settings.dart';

/// Serializes a list of Firefly transactions to a compact text format for Gemini.
String serializeTransactionsForGemini(List<TransactionRead> list) {
  final StringBuffer buf = StringBuffer();
  for (final TransactionRead read in list) {
    for (final TransactionSplit split in read.attributes.transactions) {
      final String date =
          intl.DateFormat('yyyy-MM-dd').format(split.date);
      final String amount = split.amount;
      final String currency = split.currencyCode ?? '';
      final String desc = split.description;
      final String category = split.categoryName ?? '';
      buf.writeln('$date | $amount $currency | $desc${category.isEmpty ? '' : ' | $category'}');
    }
  }
  return buf.toString();
}

/// Resolves (start, end) from range and optional custom dates (same logic as dashboard).
(DateTime start, DateTime end) resolveAnalyzeDateRange(
  DashboardDateRange range,
  DateTime? customStart,
  DateTime? customEnd,
  DateTime now,
) {
  late DateTime start;
  late DateTime end;
  switch (range) {
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
      start = customStart ?? now.subtract(const Duration(days: 30));
      end = customEnd ?? now;
      break;
  }
  return (start, end);
}

/// AI-themed loading animation: twinkling stars / sparkles.
class _AIStarsLoadingAnimation extends StatefulWidget {
  const _AIStarsLoadingAnimation();

  @override
  State<_AIStarsLoadingAnimation> createState() => _AIStarsLoadingAnimationState();
}

class _AIStarsLoadingAnimationState extends State<_AIStarsLoadingAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  static const int _starCount = 7;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 120,
      height: 120,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          return CustomPaint(
            painter: _StarsPainter(
              progress: _controller.value,
              color: color,
              starCount: _starCount,
            ),
            size: const Size(120, 120),
          );
        },
      ),
    );
  }
}

class _StarsPainter extends CustomPainter {
  _StarsPainter({
    required this.progress,
    required this.color,
    required this.starCount,
  });

  final double progress;
  final Color color;
  final int starCount;

  @override
  void paint(Canvas canvas, Size size) {
    final double centerX = size.width / 2;
    final double centerY = size.height / 2;
    const double radius = 38;

    for (int i = 0; i < starCount; i++) {
      final double angle = (i / starCount) * 2 * math.pi + progress * 2 * math.pi;
      final double x = centerX + radius * math.cos(angle);
      final double y = centerY + radius * math.sin(angle);
      final double phase = (progress + i / starCount) % 1.0;
      final double opacity = (math.sin(phase * 2 * math.pi) + 1) * 0.4 + 0.35;
      final Paint paint = Paint()
        ..color = color.withOpacity(opacity.clamp(0.0, 1.0))
        ..style = PaintingStyle.fill;

      _drawStar(canvas, Offset(x, y), 8, 4, paint);
    }
  }

  void _drawStar(Canvas canvas, Offset center, double outer, double inner, Paint paint) {
    const int points = 5;
    final ui.Path path = ui.Path();
    for (int i = 0; i < points * 2; i++) {
      final double angle = (i * math.pi / points) - math.pi / 2;
      final double r = i.isEven ? outer : inner;
      final Offset p = Offset(center.dx + r * math.cos(angle), center.dy + r * math.sin(angle));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _StarsPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class HomeAnalyze extends StatefulWidget {
  const HomeAnalyze({super.key});

  @override
  State<HomeAnalyze> createState() => _HomeAnalyzeState();
}

class _HomeAnalyzeState extends State<HomeAnalyze> {
  bool _loading = false;
  String? _resultText;
  String? _errorMessage;

  Future<void> _runAnalysis({
    required DateTime start,
    required DateTime end,
    required String prompt,
  }) async {
    final FireflyService firefly = context.read<FireflyService>();
    final String? geminiKey = await firefly.getGeminiApiKey();
    if (geminiKey == null || geminiKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).analyzeAddGeminiKeyInSettings),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    setState(() {
      _loading = true;
      _resultText = null;
      _errorMessage = null;
    });

    try {
      final TransStock? stock = firefly.transStock;
      if (stock == null) {
        throw Exception('Transaction list not available');
      }
      // Use the same request and date format as the Transactions tab.
      final String startStr = intl.DateFormat('yyyy-MM-dd', 'en_US').format(start);
      final String endStr = intl.DateFormat('yyyy-MM-dd', 'en_US').format(end);
      final List<TransactionRead> all = <TransactionRead>[];
      int page = 1;
      const int limit = 50;

      while (true) {
        final List<TransactionRead> data = await stock.get(
          page: page,
          limit: limit,
          start: startStr,
          end: endStr,
          type: TransactionTypeFilter.all,
        );
        all.addAll(data);
        if (data.length < limit) break;
        page++;
      }

      if (all.isEmpty) {
        if (mounted) {
          setState(() {
            _loading = false;
            _errorMessage = S.of(context).analyzeErrorNoTransactions;
          });
        }
        return;
      }

      final String dataText = serializeTransactionsForGemini(all);
      final String userPrompt = prompt.trim().isEmpty
          ? 'Please summarize spending and give brief insights.'
          : prompt.trim();
      final String fullPrompt =
          'You are a financial assistant. Below are the user\'s transactions for the given period (date | amount currency | description | category).\n\n'
          'Transactions:\n$dataText\n\n'
          'User request: $userPrompt';

      final Uri uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent',
      );
      final http.Response geminiResp = await http.post(
        uri,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'x-goog-api-key': geminiKey,
        },
        body: jsonEncode(<String, dynamic>{
          'contents': <Map<String, dynamic>>[
            <String, dynamic>{
              'role': 'user',
              'parts': <Map<String, dynamic>>[
                <String, dynamic>{'text': fullPrompt},
              ],
            },
          ],
        }),
      );

      if (geminiResp.statusCode != 200) {
        String msg = 'Gemini API error: ${geminiResp.statusCode}';
        try {
          final Map<String, dynamic> errBody =
              jsonDecode(geminiResp.body) as Map<String, dynamic>;
          final Map<String, dynamic>? error = errBody['error'] as Map<String, dynamic>?;
          final String? detail = error?['message'] as String?;
          if (detail != null && detail.isNotEmpty) {
            msg = '$msg — $detail';
          }
        } catch (_) {}
        throw Exception(msg);
      }
      final Map<String, dynamic> json = jsonDecode(geminiResp.body) as Map<String, dynamic>;
      final List<dynamic>? candidates = json['candidates'] as List<dynamic>?;
      String? text;
      if (candidates != null && candidates.isNotEmpty) {
        final Map<String, dynamic>? first = candidates[0] as Map<String, dynamic>?;
        final Map<String, dynamic>? content = first?['content'] as Map<String, dynamic>?;
        final List<dynamic>? parts = content?['parts'] as List<dynamic>?;
        if (parts != null && parts.isNotEmpty) {
          final Map<String, dynamic>? part = parts[0] as Map<String, dynamic>?;
          text = part?['text'] as String?;
        }
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _resultText = text ?? '';
          _errorMessage = text == null ? S.of(context).analyzeErrorApi : null;
        });
      }
    } catch (e, st) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMessage = S.of(context).analyzeErrorApi;
        });
      }
      debugPrint('Analyze error: $e $st');
    }
  }

  void _openDialog() {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => _AnalyzeRangeDialog(
        onRun: (DateTime start, DateTime end, String prompt) {
          Navigator.of(context).pop();
          _runAnalysis(start: start, end: end, prompt: prompt);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);

    if (_loading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const _AIStarsLoadingAnimation(),
            const SizedBox(height: 16),
            Text(l10n.analyzeLoading),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _openDialog,
                child: Text(l10n.analyzeAgain),
              ),
            ],
          ),
        ),
      );
    }

    if (_resultText != null && _resultText!.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.tonal(
              onPressed: _openDialog,
              child: Text(l10n.analyzeAgain),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: SelectableText(
                _resultText!,
                textDirection: _resultText!.trim().isEmpty
                    ? null
                    : (intl.Bidi.detectRtlDirectionality(_resultText!)
                        ? TextDirection.rtl
                        : TextDirection.ltr),
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ),
        ],
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              l10n.analyzeSelectRangeButton,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _openDialog,
              child: Text(l10n.analyzeSelectRangeButton),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnalyzeRangeDialog extends StatefulWidget {
  const _AnalyzeRangeDialog({required this.onRun});

  final void Function(DateTime start, DateTime end, String prompt) onRun;

  @override
  State<_AnalyzeRangeDialog> createState() => _AnalyzeRangeDialogState();
}

class _AnalyzeRangeDialogState extends State<_AnalyzeRangeDialog> {
  late DashboardDateRange _range;
  late DateTime? _customStart;
  late DateTime? _customEnd;
  final TextEditingController _promptController = TextEditingController();
  final FocusNode _promptFocusNode = FocusNode();
  TextDirection? _promptTextDirection;

  @override
  void initState() {
    super.initState();
    _range = DashboardDateRange.last30Days;
    final DateTime now = DateTime.now();
    _customStart = now.subtract(const Duration(days: 30));
    _customEnd = now;
    // Update direction only on paste or when focus leaves the field. Updating
    // on keystroke breaks IME composition (e.g. Hebrew typing).
    _promptFocusNode.addListener(_onPromptFocusChange);
  }

  void _onPromptFocusChange() {
    if (!_promptFocusNode.hasFocus && mounted) {
      final String text = _promptController.text;
      final TextDirection? dir = text.trim().isEmpty
          ? null
          : (intl.Bidi.detectRtlDirectionality(text)
              ? TextDirection.rtl
              : TextDirection.ltr);
      if (dir != _promptTextDirection) {
        setState(() => _promptTextDirection = dir);
      }
    }
  }

  Future<void> _pastePrompt() async {
    final ClipboardData? data =
        await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;
    if (text != null && mounted) {
      setState(() {
        _promptController.text = text;
        _promptTextDirection = text.trim().isEmpty
            ? null
            : (intl.Bidi.detectRtlDirectionality(text)
                ? TextDirection.rtl
                : TextDirection.ltr);
      });
    }
  }

  @override
  void dispose() {
    _promptFocusNode.removeListener(_onPromptFocusChange);
    _promptFocusNode.dispose();
    _promptController.dispose();
    super.dispose();
  }

  String _rangeLabel(BuildContext context, DashboardDateRange r) {
    switch (r) {
      case DashboardDateRange.last7Days:
        return S.of(context).homeMainFilterLast7Days;
      case DashboardDateRange.last30Days:
        return S.of(context).homeMainFilterLast30Days;
      case DashboardDateRange.currentMonth:
        return S.of(context).homeMainFilterCurrentMonth;
      case DashboardDateRange.last3Months:
        return S.of(context).homeMainFilterLast3Months;
      case DashboardDateRange.last12Months:
        return S.of(context).homeMainFilterLast12Months;
      case DashboardDateRange.custom:
        return S.of(context).homeMainFilterCustomRange;
    }
  }

  void _onAnalyze() {
    final DateTime now = DateTime.now();
    final (DateTime start, DateTime end) = resolveAnalyzeDateRange(
      _range,
      _customStart,
      _customEnd,
      now,
    );
    widget.onRun(start, end, _promptController.text);
  }

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    return AlertDialog(
      title: Text(l10n.analyzeDialogTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.homeMainFilterTimeFrame),
            const SizedBox(height: 8),
            DropdownButtonFormField<DashboardDateRange>(
              // ignore: deprecated_member_use - value deprecated in favor of initialValue in Flutter 3.35+
              value: _range,
              items: DashboardDateRange.values
                  .map(
                    (DashboardDateRange r) => DropdownMenuItem<DashboardDateRange>(
                      value: r,
                      child: Text(_rangeLabel(context, r)),
                    ),
                  )
                  .toList(),
              onChanged: (DashboardDateRange? value) {
                if (value != null) {
                  setState(() {
                    _range = value;
                    if (value == DashboardDateRange.custom &&
                        _customStart == null &&
                        _customEnd == null) {
                      final DateTime now = DateTime.now();
                      _customStart = now.subtract(const Duration(days: 30));
                      _customEnd = now;
                    }
                  });
                }
              },
            ),
            if (_range == DashboardDateRange.custom) ...<Widget>[
              const SizedBox(height: 16),
              ListTile(
                title: Text(
                  _customStart != null
                      ? intl.DateFormat.yMMMd().format(_customStart!)
                      : 'Start',
                ),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final DateTime? picked = await showDatePicker(
                    context: context,
                    initialDate: _customStart ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null && mounted) {
                    setState(() {
                      _customStart = picked;
                      if (_customEnd != null && _customEnd!.isBefore(picked)) {
                        _customEnd = picked;
                      }
                    });
                  }
                },
              ),
              ListTile(
                title: Text(
                  _customEnd != null
                      ? intl.DateFormat.yMMMd().format(_customEnd!)
                      : 'End',
                ),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final DateTime? picked = await showDatePicker(
                    context: context,
                    initialDate: _customEnd ?? DateTime.now(),
                    firstDate: _customStart ?? DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null && mounted) {
                    setState(() {
                      _customEnd = picked;
                      if (_customStart != null &&
                          _customStart!.isAfter(picked)) {
                        _customStart = picked;
                      }
                    });
                  }
                },
              ),
            ],
            const SizedBox(height: 24),
            Text(l10n.analyzePromptLabel),
            const SizedBox(height: 8),
            TextFormField(
              controller: _promptController,
              focusNode: _promptFocusNode,
              textDirection: _promptTextDirection,
              decoration: InputDecoration(
                hintText: l10n.analyzePromptHint,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste),
                  onPressed: _pastePrompt,
                  tooltip: MaterialLocalizations.of(context).pasteButtonLabel,
                ),
              ),
              maxLines: 3,
              minLines: 2,
              enableInteractiveSelection: true,
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _onAnalyze,
          child: Text(l10n.analyzeButtonRun),
        ),
      ],
    );
  }
}
