import 'package:flutter/material.dart';

import '../../core/formatters.dart';

/// Compact From/To date picker shown above ledger tables.
///
/// Either bound may be null (open-ended). The "Clear" affordance only
/// appears when at least one bound is set, so the bar collapses back to
/// "All dates" without extra clutter.
///
/// The user picks dates with the platform date picker; we never edit raw
/// ISO strings so there's no validation needed beyond the picker's own
/// firstDate/lastDate clamping.
class DateRangeBar extends StatelessWidget {
  const DateRangeBar({
    super.key,
    required this.from,
    required this.to,
    required this.onChanged,
  });

  final DateTime? from;
  final DateTime? to;
  final void Function(DateTime? from, DateTime? to) onChanged;

  Future<void> _pickFrom(BuildContext context) async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: from ?? to ?? today,
      firstDate: DateTime(2000),
      lastDate: DateTime(today.year + 5),
      helpText: 'Period — From',
    );
    if (picked == null) return;
    // If the user picks a `from` after the current `to`, snap `to` to
    // match so the range stays valid without an extra dialog.
    final newTo = (to != null && picked.isAfter(to!)) ? picked : to;
    onChanged(picked, newTo);
  }

  Future<void> _pickTo(BuildContext context) async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: to ?? from ?? today,
      firstDate: from ?? DateTime(2000),
      lastDate: DateTime(today.year + 5),
      helpText: 'Period — To',
    );
    if (picked == null) return;
    onChanged(from, picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasRange = from != null || to != null;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.event,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 4,
                children: [
                  _DateChip(
                    label: 'From',
                    value: from,
                    onPressed: () => _pickFrom(context),
                  ),
                  _DateChip(
                    label: 'To',
                    value: to,
                    onPressed: () => _pickTo(context),
                  ),
                ],
              ),
            ),
            if (hasRange)
              IconButton(
                tooltip: 'Clear period',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => onChanged(null, null),
              ),
          ],
        ),
      ),
    );
  }
}

class _DateChip extends StatelessWidget {
  const _DateChip({
    required this.label,
    required this.value,
    required this.onPressed,
  });

  final String label;
  final DateTime? value;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: const Icon(Icons.calendar_today, size: 14),
      label: Text(value == null ? '$label: any' : '$label: ${fmtDate(value!)}'),
      onPressed: onPressed,
    );
  }
}

/// Returns "1 Jan 2025 → 31 Mar 2025" for a from/to pair, or
/// "All dates" / "Up to 31 Mar 2025" / "From 1 Jan 2025 onwards" for the
/// open-ended cases. Used as the period label on PDF/CSV exports.
String formatPeriod(DateTime? from, DateTime? to) {
  if (from == null && to == null) return 'All dates';
  if (from != null && to != null) return '${fmtDate(from)} → ${fmtDate(to)}';
  if (from != null) return 'From ${fmtDate(from)} onwards';
  return 'Up to ${fmtDate(to!)}';
}
