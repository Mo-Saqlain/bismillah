import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';
import '../../core/export/csv_export.dart';

/// Project Profitability Summary — one row per project with the
/// bottom-line numbers an owner cares about: revenue received, money
/// spent, and the resulting net position.
///
/// For With-Material projects, "Net" is `budget − spent` — the projected
/// profit at close, which doubles as a "headroom" metric while the
/// project is in-progress (how much you can still spend before the job
/// becomes unprofitable). Avoids the fake-profit trap that
/// `received − spent` would produce when a customer prepays.
///
/// For Labour-Rate projects, "Net" is the booked Service Fee Income for
/// that project (the contractor's earnings; the rest is pass-through).
///
/// Sorted by profitability descending so the most lucrative job is on
/// top. Toggles between active and archived projects.
class ProjectProfitabilityScreen extends ConsumerStatefulWidget {
  const ProjectProfitabilityScreen({super.key});

  @override
  ConsumerState<ProjectProfitabilityScreen> createState() =>
      _ProjectProfitabilityScreenState();
}

class _ProjectProfitabilityScreenState
    extends ConsumerState<ProjectProfitabilityScreen> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(_profitabilityProvider(_showArchived));
    return Scaffold(
      appBar: AppBar(
        title: Text(_showArchived
            ? 'Closed Project Profitability'
            : 'Project Profitability'),
        actions: [
          IconButton(
            tooltip: _showArchived
                ? 'Show active projects'
                : 'View closed projects',
            icon: Icon(_showArchived
                ? Icons.unarchive_outlined
                : Icons.archive_outlined),
            onPressed: () => setState(() => _showArchived = !_showArchived),
          ),
          IconButton(
            tooltip: 'Export CSV',
            icon: const Icon(Icons.file_download, size: 26),
            onPressed: () async {
              final list = await ref
                  .read(_profitabilityProvider(_showArchived).future);
              await _exportCsv(list);
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AsyncView<List<_ProfitabilityRow>>(
        value: dataAsync,
        data: (rows) {
          if (rows.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_showArchived
                    ? 'No closed projects yet.'
                    : 'No active projects yet.'),
              ),
            );
          }
          final grandRevenue =
              rows.fold<double>(0, (a, r) => a + r.revenue);
          final grandSpent = rows.fold<double>(0, (a, r) => a + r.spent);
          final grandNet = rows.fold<double>(0, (a, r) => a + r.net);

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _SummaryCard(
                projects: rows.length,
                revenue: grandRevenue,
                spent: grandSpent,
                net: grandNet,
              ),
              const SizedBox(height: 8),
              Card(
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Project')),
                      DataColumn(label: Text('Model')),
                      DataColumn(label: Text('Received'), numeric: true),
                      DataColumn(label: Text('Spent'), numeric: true),
                      DataColumn(label: Text('Net'), numeric: true),
                    ],
                    rows: [
                      for (final r in rows)
                        DataRow(cells: [
                          DataCell(Text(r.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600))),
                          DataCell(Text(r.model.label,
                              style: const TextStyle(fontSize: 12))),
                          DataCell(Text(fmtMoney(r.revenue))),
                          DataCell(Text(fmtMoney(r.spent))),
                          DataCell(Text(fmtSignedMoney(r.net),
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: BalanceColors.signed(context, r.net)))),
                        ]),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // ── Net profit bar chart ───────────────────────────────────────
              if (rows.isNotEmpty) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Net Profit per Project',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 12),
                        _ProfitabilityChart(rows: rows),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                'Net = budget − spent for With-Material projects (the '
                'projected profit at close — your headroom while in-progress, '
                'realized profit once archived; goes red when costs overrun '
                'budget). For Labour-Rate projects, Net is the booked '
                'service-fee income (the contractor\'s earnings — the rest '
                'is customer money passing through).',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _exportCsv(List<_ProfitabilityRow> rows) async {
    final csv = CsvExport.build(
      headers: const ['Project', 'Model', 'Received', 'Spent', 'Net'],
      rows: [
        for (final r in rows)
          [
            r.name,
            r.model.label,
            r.revenue.toStringAsFixed(2),
            r.spent.toStringAsFixed(2),
            r.net.toStringAsFixed(2),
          ],
      ],
    );
    await CsvExport.share(
      fileName:
          'project_profitability_${DateTime.now().millisecondsSinceEpoch}',
      csv: csv,
      subject: 'Project Profitability Summary',
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.projects,
    required this.revenue,
    required this.spent,
    required this.net,
  });
  final int projects;
  final double revenue;
  final double spent;
  final double net;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$projects project${projects == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(fmtSignedMoney(net),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: BalanceColors.signed(context, net),
                    )),
            Text('Total net result',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: [
                _Stat(label: 'Received', value: revenue),
                _Stat(label: 'Spent', value: spent),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(fmtMoney(value),
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _ProfitabilityRow {
  final String id;
  final String name;
  final ProjectModel model;
  final double revenue;
  final double spent;
  final double net;
  const _ProfitabilityRow({
    required this.id,
    required this.name,
    required this.model,
    required this.revenue,
    required this.spent,
    required this.net,
  });
}

class _ProfitabilityChart extends StatelessWidget {
  const _ProfitabilityChart({required this.rows});
  final List<_ProfitabilityRow> rows;

  @override
  Widget build(BuildContext context) {
    final maxAbs =
        rows.fold<double>(0, (m, r) => r.net.abs() > m ? r.net.abs() : m);
    if (maxAbs == 0) return const SizedBox.shrink();

    final hasNegative = rows.any((r) => r.net < 0);
    final maxY = maxAbs * 1.25;
    final minY = hasNegative ? -maxAbs * 1.25 : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Each bar = one project\'s projected profit (budget − spent for WM, '
          'service fee for LR). Green = on track, red = costs already over budget.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 200,
          child: BarChart(
            BarChartData(
              maxY: maxY,
              minY: minY,
              barGroups: rows.asMap().entries.map((e) {
                final net = e.value.net;
                return BarChartGroupData(
                  x: e.key,
                  barRods: [
                    BarChartRodData(
                      toY: net,
                      color: net >= 0
                          ? BalanceColors.positive(context)
                          : BalanceColors.negative(context),
                      width: _barWidth(rows.length),
                      borderRadius: net >= 0
                          ? const BorderRadius.vertical(top: Radius.circular(3))
                          : const BorderRadius.vertical(
                              bottom: Radius.circular(3)),
                    ),
                  ],
                );
              }).toList(),
              titlesData: FlTitlesData(
                bottomTitles: AxisTitles(
                  axisNameWidget: Text('Project',
                      style: Theme.of(context).textTheme.labelSmall),
                  axisNameSize: 14,
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    getTitlesWidget: (v, _) {
                      final i = v.toInt();
                      if (i < 0 || i >= rows.length) {
                        return const SizedBox.shrink();
                      }
                      final name = rows[i].name;
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          name.length > 9 ? '${name.substring(0, 9)}…' : name,
                          style: const TextStyle(fontSize: 9),
                          textAlign: TextAlign.center,
                        ),
                      );
                    },
                  ),
                ),
                leftTitles: AxisTitles(
                  axisNameWidget: Text('Net (Rs)',
                      style: Theme.of(context).textTheme.labelSmall),
                  axisNameSize: 14,
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 52,
                    interval: _yAxisInterval(maxAbs),
                    getTitlesWidget: (v, _) => Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        fmtCompactMoney(v),
                        style: const TextStyle(fontSize: 9),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ),
                ),
                topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
              ),
              borderData: FlBorderData(show: false),
              // Bold zero line so positive vs negative is unmistakable.
              extraLinesData: ExtraLinesData(horizontalLines: [
                HorizontalLine(
                  y: 0,
                  color:
                      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  strokeWidth: 1,
                ),
              ]),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: _yAxisInterval(maxAbs),
                getDrawingHorizontalLine: (_) => FlLine(
                  color: Theme.of(context)
                      .colorScheme
                      .outlineVariant
                      .withValues(alpha: 0.4),
                  strokeWidth: 1,
                ),
              ),
              barTouchData: BarTouchData(
                enabled: true,
                touchTooltipData: BarTouchTooltipData(
                  getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                    '${rows[group.x].name}\n${fmtSignedMoney(rod.toY)}',
                    const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 11),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  double _barWidth(int count) {
    if (count <= 5) return 20;
    if (count <= 10) return 14;
    return 10;
  }

  double _yAxisInterval(double maxAbs) {
    if (maxAbs <= 0) return 1;
    final raw = maxAbs / 4;
    var mag = 1.0;
    while (mag * 10 <= raw) {
      mag *= 10;
    }
    while (mag > raw && mag > 1e-9) {
      mag /= 10;
    }
    final norm = raw / mag;
    final nice = norm < 1.5
        ? 1.0
        : norm < 3
            ? 2.0
            : norm < 7
                ? 5.0
                : 10.0;
    return nice * mag;
  }
}

/// Pulls every project (active or archived per [archived]) and asks the
/// ledger for the cost / revenue / fee-income aggregates per project,
/// then computes a single Net per row depending on the project model.
final _profitabilityProvider =
    FutureProvider.family<List<_ProfitabilityRow>, bool>((ref, archived) async {
  ref.watch(ledgerVersionProvider);
  final entityRepo = await ref.watch(entityRepoProvider.future);
  final ledger = await ref.watch(ledgerRepoProvider.future);

  final projects = archived
      ? await entityRepo.archivedProjects()
      : await entityRepo.projects(activeOnly: true);

  final rows = <_ProfitabilityRow>[];
  for (final p in projects) {
    final spent = await ledger.projectOutflow(p.id);
    final revenue = await ledger.sumCredits(Accounts.projectRevenue.id,
        projectId: p.id);
    final feeIncome = await ledger.sumCredits(Accounts.serviceFeeIncome.id,
        projectId: p.id);

    // Net for the contractor:
    //   * With-Material: `budget − spent` — the projected profit at
    //     close, assuming no more spending. While the project is
    //     in-progress this reads as "headroom" (how much room you have
    //     before this becomes unprofitable). Once archived, costs are
    //     final and the formula gives the realized profit. We deliberately
    //     do NOT use `received − spent` because that's the same fake-
    //     profit pattern PoC fixes in the Income Statement — it would
    //     flash a big positive number the moment a customer prepays,
    //     before any work is done.
    //   * Labour-Rate: profit = booked service fee (pass-through model).
    //   * No-budget legacy fallback: if budget is null (only possible on
    //     pre-existing projects since budgets are now required on WM),
    //     fall back to received − spent so the row still shows
    //     *something* meaningful.
    final double net;
    if (p.model == ProjectModel.labourRate) {
      net = feeIncome;
    } else if (p.budget != null && p.budget! > 0) {
      net = p.budget! - spent;
    } else {
      net = revenue - spent;
    }

    rows.add(_ProfitabilityRow(
      id: p.id,
      name: p.name,
      model: p.model,
      revenue: revenue,
      spent: spent,
      net: net,
    ));
  }
  rows.sort((a, b) => b.net.compareTo(a.net));
  return rows;
});
