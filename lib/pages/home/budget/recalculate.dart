import 'package:flutter/material.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';

/// The "tell the AI what to fix" box.
///
/// Whatever is typed here is saved as a standing rule and replayed into every
/// later analysis, so a correction only has to be made once.
class RecalculateBox extends StatefulWidget {
  const RecalculateBox({
    super.key,
    required this.hintText,
    required this.rules,
    required this.onSubmit,
  });

  final String hintText;
  final List<String> rules;
  final Future<void> Function(String rule) onSubmit;

  @override
  State<RecalculateBox> createState() => _RecalculateBoxState();
}

class _RecalculateBoxState extends State<RecalculateBox> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await widget.onSubmit(_controller.text);
      if (mounted) {
        _controller.clear();
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final ThemeData theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            l10n.budgetRecalculateTitle,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            minLines: 1,
            maxLines: 3,
            enabled: !_busy,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              hintText: widget.hintText,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              if (widget.rules.isNotEmpty)
                Expanded(
                  child: Text(
                    l10n.budgetSavedRules(widget.rules.length),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                const Spacer(),
              FilledButton.icon(
                onPressed: _busy ? null : _submit,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: Text(l10n.budgetRecalculate),
              ),
            ],
          ),
          if (widget.rules.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: widget.rules
                  .map(
                    (String rule) => Chip(
                      label: Text(rule),
                      labelStyle: theme.textTheme.bodySmall,
                      visualDensity: VisualDensity.compact,
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}
