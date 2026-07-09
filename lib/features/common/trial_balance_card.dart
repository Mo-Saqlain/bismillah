import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';

/// A single row in a [TrialBalanceCard]. The caller decides which rows
/// belong on which ledger — typical pattern is:
///
///   * Total Debits
///   * Total Credits
///   * Net / Outstanding (signed, color-coded)
///
/// `colorize` carries the sign used for emerald/rose colouring; set it
/// to the row's `value` for "positive = good" colouring, or to
/// `-value` to invert (e.g. a supplier payable: positive arithmetic
/// balance means we owe — that's bad → red).
class TrialBalanceRow {
  final String label;
  final double value;
  final bool bold;
  final double? colorize;

  /// Optional sub-label rendered in small text under [label] — used
  /// for the "Net" row to spell out the formula (e.g. "Dr − Cr").
  final String? helper;

  const TrialBalanceRow({
    required this.label,
    required this.value,
    this.bold = false,
    this.colorize,
    this.helper,
  });
}

/// Trial-balance header card that sits at the top of a ledger screen.
///
/// The card answers "what's the dr/cr summary for this view?" — the
/// classical trial balance for one account scope. Pure presentation:
/// rows are computed by the caller from the already-loaded ledger
/// entries so the math stays in sync with whatever filters the user
/// has applied.
class TrialBalanceCard extends StatelessWidget {
  const TrialBalanceCard({
    super.key,
    required this.title,
    required this.rows,
    this.entryCount,
  });

  /// Section heading, e.g. "Trial balance · Site A · Last 30 days".
  final String title;

  /// Three to five rows is the sweet spot — more than that and the card
  /// stops being a "glanceable" summary.
  final List<TrialBalanceRow> rows;

  /// Optional small badge in the header (e.g. "12 entries").
  final int? entryCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.balance,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
                ),
                if (entryCount != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$entryCount entr${entryCount == 1 ? "y" : "ies"}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            for (final row in rows) _Row(row: row),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.row});
  final TrialBalanceRow row;

  @override
  Widget build(BuildContext context) {
    final color = row.colorize == null
        ? null
        : BalanceColors.signed(context, row.colorize!);
    final style = TextStyle(
      fontWeight: row.bold ? FontWeight.w700 : FontWeight.w500,
      color: color,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.label,
                    style: TextStyle(
                      fontWeight: row.bold ? FontWeight.w700 : FontWeight.w500,
                    )),
                if (row.helper != null)
                  Text(row.helper!,
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Text(
            row.colorize == null ? fmtMoney(row.value) : fmtSignedMoney(row.value),
            style: style,
          ),
        ],
      ),
    );
  }
}

/// Per-supplier / per-material-type roll-up shown only on the Project
/// Ledger screen — the user wanted to see "where did the money go for
/// this project" broken down two ways. Takes the already-aggregated
/// lists returned by `LedgerRepository.projectSupplierBreakdown` /
/// `projectMaterialBreakdown` plus a supplier-id → name map so we can
/// render the supplier rows with human-readable labels.
class ProjectBreakdownCard extends StatelessWidget {
  const ProjectBreakdownCard({
    super.key,
    required this.materialRows,
    required this.supplierRows,
    required this.supplierNames,
    this.maxRows = 8,
  });

  /// `(materialType, total)` rows, already sorted highest-first.
  final List<({String materialType, double total})> materialRows;

  /// `(supplierId, total)` rows, already sorted highest-first. An empty
  /// supplierId represents counter-purchase spend (no supplier).
  final List<({String supplierId, double total})> supplierRows;

  /// Maps supplier id → display name. Missing entries fall back to the
  /// id itself; the empty-string key (counter purchase) is rendered as
  /// "Counter purchase".
  final Map<String, String> supplierNames;

  /// How many breakdown rows to show per section before "+ N more".
  final int maxRows;

  @override
  Widget build(BuildContext context) {
    if (materialRows.isEmpty && supplierRows.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.pie_chart_outline,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text('Project breakdown',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    )),
              ],
            ),
            const SizedBox(height: 8),
            if (supplierRows.isNotEmpty) ...[
              _Section(
                title: 'By supplier',
                rows: supplierRows
                    .take(maxRows)
                    .map((r) => _BreakdownLine(
                          label: r.supplierId.isEmpty
                              ? 'Counter purchase (no supplier)'
                              : (supplierNames[r.supplierId] ?? r.supplierId),
                          value: r.total,
                        ))
                    .toList(),
                hiddenCount: supplierRows.length > maxRows
                    ? supplierRows.length - maxRows
                    : 0,
              ),
              const SizedBox(height: 10),
            ],
            if (materialRows.isNotEmpty)
              _Section(
                title: 'By material type',
                rows: materialRows
                    .take(maxRows)
                    .map((r) => _BreakdownLine(
                          label: r.materialType,
                          value: r.total,
                        ))
                    .toList(),
                hiddenCount: materialRows.length > maxRows
                    ? materialRows.length - maxRows
                    : 0,
              ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.rows,
    required this.hiddenCount,
  });
  final String title;
  final List<_BreakdownLine> rows;
  final int hiddenCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
        const SizedBox(height: 4),
        for (final r in rows) r,
        if (hiddenCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '+ $hiddenCount more',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _BreakdownLine extends StatelessWidget {
  const _BreakdownLine({required this.label, required this.value});
  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
          Text(fmtMoney(value),
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
