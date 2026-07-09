import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/export/csv_export.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/repositories/ledger_repository.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';

/// Monthly P&L Trend — recognized income, costs and net profit per month
/// for the last 12 months. Same recognition basis as the Income Statement
/// (cost-recovery PoC for With-Material projects, service fees for
/// Labour-Rate). Rendered as a line chart over a breakdown table.
class IncomeTrendScreen extends ConsumerWidget {
  const IncomeTrendScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(ledgerVersionProvider);
    final trend = ref.watch(_monthlyIncomeProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monthly P&L Trend'),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: const Icon(Icons.file_download, size: 26),
            onPressed: () async {
              final rows = await ref.read(_monthlyIncomeProvider.future);
              await _exportCsv(rows);
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AsyncView(
        value: trend,
        data: (rows) {
          if (rows.every((r) => r.income == 0 && r.costs == 0)) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No income or costs in the last 12 months.'),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _TrendChartCard(rows: rows),
              const SizedBox(height: 16),
              Text('Monthly breakdown',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _BreakdownTable(rows: rows),
              const SizedBox(height: 12),
              Text(
                'Income is recognized revenue (cost-recovery for With-Material '
                'projects, full contract on close) plus service fees earned. '
                'Costs include material, labour and owner draws. The '
                'forward-looking loss provision shown on the Income Statement '
                'is excluded here — it is a point-in-time figure, not a '
                'monthly flow.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _exportCsv(List<MonthlyIncome> rows) async {
    final monthFmt = DateFormat('yyyy-MM');
    final csv = CsvExport.build(
      headers: const [
        'Month',
        'Income',
        'Material',
        'Labour',
        'Owner Draw',
        'Total Costs',
        'Net Profit',
      ],
      rows: [
        for (final m in rows)
          [
            monthFmt.format(m.month),
            m.income.toStringAsFixed(2),
            m.materialCosts.toStringAsFixed(2),
            m.labourCosts.toStringAsFixed(2),
            m.personalDraw.toStringAsFixed(2),
            m.costs.toStringAsFixed(2),
            m.netProfit.toStringAsFixed(2),
          ],
      ],
    );
    await CsvExport.share(
      fileName: 'pnl_trend_${DateTime.now().millisecondsSinceEpoch}',
      csv: csv,
      subject: 'Monthly P&L Trend',
    );
  }
}

final _monthlyIncomeProvider =
    FutureProvider<List<MonthlyIncome>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  return repo.monthlyIncome();
});

class _TrendChartCard extends StatelessWidget {
  const _TrendChartCard({required this.rows});
  final List<MonthlyIncome> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final monthFmt = DateFormat('MMM');

    final incomeSpots = <FlSpot>[];
    final costSpots = <FlSpot>[];
    final netSpots = <FlSpot>[];
    var minY = 0.0;
    var maxY = 0.0;
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      incomeSpots.add(FlSpot(i.toDouble(), r.income));
      costSpots.add(FlSpot(i.toDouble(), r.costs));
      netSpots.add(FlSpot(i.toDouble(), r.netProfit));
      for (final v in [r.income, r.costs, r.netProfit]) {
        if (v > maxY) maxY = v;
        if (v < minY) minY = v;
      }
    }
    // Pad the range a touch so peaks/troughs aren't flush against the edge.
    final span = (maxY - minY).abs();
    final pad = span == 0 ? 1.0 : span * 0.12;

    final incomeColor = BalanceColors.positive(context);
    final costColor = BalanceColors.negative(context);
    final netColor = scheme.primary;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Wrap(
                spacing: 16,
                children: [
                  _Legend(color: incomeColor, label: 'Income'),
                  _Legend(color: costColor, label: 'Costs'),
                  _Legend(color: netColor, label: 'Net Profit'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 240,
              child: LineChart(LineChartData(
                minY: minY - pad,
                maxY: maxY + pad,
                lineBarsData: [
                  _bar(incomeSpots, incomeColor),
                  _bar(costSpots, costColor),
                  _bar(netSpots, netColor, width: 3),
                ],
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      interval: 1,
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= rows.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            monthFmt.format(rows[i].month.toLocal()),
                            style: const TextStyle(fontSize: 9),
                          ),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 52,
                      getTitlesWidget: (v, _) => Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(fmtCompactMoney(v),
                            style: const TextStyle(fontSize: 9),
                            textAlign: TextAlign.right),
                      ),
                    ),
                  ),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                ),
                borderData: FlBorderData(show: false),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: scheme.outlineVariant.withValues(alpha: 0.4),
                    strokeWidth: 1,
                  ),
                ),
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (touchedSpots) => touchedSpots.map((s) {
                      final m = rows[s.spotIndex];
                      final label = switch (s.barIndex) {
                        0 => 'Income',
                        1 => 'Costs',
                        _ => 'Net',
                      };
                      return LineTooltipItem(
                        '$label\n${fmtMoney(s.y)}',
                        const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 11),
                        children: s.barIndex == 0
                            ? [
                                TextSpan(
                                  text:
                                      '\n${DateFormat('MMM yyyy').format(m.month.toLocal())}',
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 9),
                                ),
                              ]
                            : null,
                      );
                    }).toList(),
                  ),
                ),
              )),
            ),
          ],
        ),
      ),
    );
  }

  LineChartBarData _bar(List<FlSpot> spots, Color color, {double width = 2.5}) =>
      LineChartBarData(
        spots: spots,
        color: color,
        barWidth: width,
        isCurved: false,
        dotData: FlDotData(
          show: true,
          getDotPainter: (spot, _, _, _) => FlDotCirclePainter(
            radius: 2.5,
            color: color,
            strokeWidth: 0,
            strokeColor: color,
          ),
        ),
      );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _BreakdownTable extends StatelessWidget {
  const _BreakdownTable({required this.rows});
  final List<MonthlyIncome> rows;

  @override
  Widget build(BuildContext context) {
    final monthFmt = DateFormat('MMM yy');
    // Newest month first so the user lands on current activity.
    final ordered = rows.reversed.toList();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Month')),
            DataColumn(label: Text('Income'), numeric: true),
            DataColumn(label: Text('Costs'), numeric: true),
            DataColumn(label: Text('Net'), numeric: true),
          ],
          rows: [
            for (final m in ordered)
              DataRow(cells: [
                DataCell(Text(monthFmt.format(m.month.toLocal()))),
                DataCell(Text(m.income == 0 ? '—' : fmtMoney(m.income))),
                DataCell(Text(m.costs == 0 ? '—' : fmtMoney(m.costs))),
                DataCell(Text(
                  fmtSignedMoney(m.netProfit),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: m.netProfit == 0
                        ? null
                        : BalanceColors.signed(context, m.netProfit),
                  ),
                )),
              ]),
          ],
        ),
      ),
    );
  }
}
