import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/models/project.dart';
import '../../data/repositories/ledger_repository.dart';
import '../../providers/providers.dart';
import '../../core/export/csv_export.dart';

enum _SpendPeriod { day, week, month }

class ProjectBvaScreen extends ConsumerStatefulWidget {
  const ProjectBvaScreen({super.key, required this.project});
  final Project project;

  @override
  ConsumerState<ProjectBvaScreen> createState() => _ProjectBvaScreenState();
}

class _ProjectBvaScreenState extends ConsumerState<ProjectBvaScreen> {
  _SpendPeriod _period = _SpendPeriod.day;

  @override
  Widget build(BuildContext context) {
    ref.watch(ledgerVersionProvider);
    final project = widget.project;
    final dataAsync = ref.watch(_bvaProvider(project.id));
    final dailyAsync = ref.watch(_projectDailySpendProvider(project.id));
    final budget = project.budget ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text('BvA · ${project.name}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download),
            tooltip: 'Export CSV',
            onPressed: () async {
              final bva = await ref.read(_bvaProvider(project.id).future);
              await _exportCsv(project, bva, budget);
            },
          ),
        ],
      ),
      body: dataAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (bva) {
          final spend = bva.totalSpend;
          final remaining = budget - spend;
          final pct = budget > 0 ? (spend / budget * 100) : 0.0;
          final overrun = budget > 0 && spend > budget;

          final categories = <(String, double)>[
            for (final e in bva.materialByType.entries)
              ('Material · ${e.key}', e.value),
            if (bva.otherMaterial > 0)
              ('Material · Other', bva.otherMaterial),
            ('Labour', bva.labour),
          ];

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              // ── Summary card ──────────────────────────────────────────────
              Card(
                color: overrun
                    ? Theme.of(context).colorScheme.errorContainer
                    : null,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Budget'),
                            Text(fmtMoney(budget),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                          ]),
                      const SizedBox(height: 4),
                      Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Actual Spend'),
                            Text(fmtMoney(spend),
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: overrun
                                        ? BalanceColors.negative(context)
                                        : null)),
                          ]),
                      const SizedBox(height: 4),
                      Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(remaining >= 0 ? 'Remaining' : 'Over Budget'),
                            Text(fmtSignedMoney(remaining),
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: BalanceColors.signed(
                                        context, remaining))),
                          ]),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: budget == 0
                            ? null
                            : (spend / budget).clamp(0, 1.0).toDouble(),
                        minHeight: 8,
                        color: overrun
                            ? BalanceColors.negative(context)
                            : BalanceColors.positive(context),
                      ),
                      const SizedBox(height: 4),
                      Text(budget == 0
                          ? 'No budget set on this project.'
                          : '${pct.toStringAsFixed(1)} % of budget consumed'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // ── Budget allocation pie chart ───────────────────────────────
              if (budget > 0 && spend > 0) ...[
                _SectionHeader('Budget Allocation'),
                _BudgetPieChart(
                  material: bva.totalMaterial,
                  labour: bva.labour,
                  remaining: remaining > 0 ? remaining : 0,
                ),
                const SizedBox(height: 8),
              ],

              // ── Material breakdown pie chart ──────────────────────────────
              if (bva.totalMaterial > 0 &&
                  (bva.materialByType.length > 1 || bva.otherMaterial > 0)) ...[
                _SectionHeader('Material Breakdown'),
                _MaterialPieChart(bva: bva),
                const SizedBox(height: 8),
              ],

              // ── Spending over time bar chart ──────────────────────────────
              _SectionHeader('Spending Over Time'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      SegmentedButton<_SpendPeriod>(
                        segments: const [
                          ButtonSegment(
                              value: _SpendPeriod.day, label: Text('Day')),
                          ButtonSegment(
                              value: _SpendPeriod.week, label: Text('Week')),
                          ButtonSegment(
                              value: _SpendPeriod.month, label: Text('Month')),
                        ],
                        selected: {_period},
                        onSelectionChanged: (s) =>
                            setState(() => _period = s.first),
                        style: const ButtonStyle(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      ),
                      const SizedBox(height: 12),
                      dailyAsync.when(
                        loading: () =>
                            const SizedBox(height: 120, child: Center(child: CircularProgressIndicator())),
                        error: (e, _) => Text('Error: $e'),
                        data: (daily) => _SpendBarChart(
                          daily: daily,
                          period: _period,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // ── Category data table ───────────────────────────────────────
              Card(
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Category')),
                      DataColumn(label: Text('Actual'), numeric: true),
                      DataColumn(label: Text('% of spend'), numeric: true),
                    ],
                    rows: [
                      for (final c in categories)
                        DataRow(cells: [
                          DataCell(Text(c.$1)),
                          DataCell(Text(fmtMoney(c.$2))),
                          DataCell(Text(spend == 0
                              ? '—'
                              : '${(c.$2 / spend * 100).toStringAsFixed(1)} %')),
                        ]),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Material costs are split using `material_inventory` rows. Costs '
                'posted directly without an inventory row appear under '
                '"Material · Other".',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _exportCsv(Project p, ProjectBva bva, double budget) async {
    final spend = bva.totalSpend;
    final csv = CsvExport.build(
      headers: ['Category', 'Actual', 'Pct of Spend'],
      rows: [
        for (final e in bva.materialByType.entries)
          [
            'Material · ${e.key}',
            e.value.toStringAsFixed(2),
            spend == 0 ? '0' : (e.value / spend * 100).toStringAsFixed(1),
          ],
        if (bva.otherMaterial > 0)
          [
            'Material · Other',
            bva.otherMaterial.toStringAsFixed(2),
            spend == 0
                ? '0'
                : (bva.otherMaterial / spend * 100).toStringAsFixed(1),
          ],
        [
          'Labour',
          bva.labour.toStringAsFixed(2),
          spend == 0 ? '0' : (bva.labour / spend * 100).toStringAsFixed(1),
        ],
        ['', '', ''],
        ['Budget', budget.toStringAsFixed(2), ''],
        ['Total Spend', spend.toStringAsFixed(2), ''],
        ['Remaining', (budget - spend).toStringAsFixed(2), ''],
      ],
    );
    await CsvExport.share(
      fileName: 'bva_${p.name}_${DateTime.now().millisecondsSinceEpoch}',
      csv: csv,
      subject: 'Budget vs Actual — ${p.name}',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Chart widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w700)),
    );
  }
}

class _BudgetPieChart extends StatelessWidget {
  const _BudgetPieChart({
    required this.material,
    required this.labour,
    required this.remaining,
  });
  final double material;
  final double labour;
  final double remaining;

  @override
  Widget build(BuildContext context) {
    final total = material + labour + remaining;
    if (total <= 0) return const SizedBox.shrink();

    final sections = [
      if (material > 0)
        PieChartSectionData(
          value: material,
          color: Colors.orange.shade600,
          title: '${(material / total * 100).toStringAsFixed(0)}%',
          radius: 55,
          titleStyle: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
        ),
      if (labour > 0)
        PieChartSectionData(
          value: labour,
          color: Colors.blue.shade600,
          title: '${(labour / total * 100).toStringAsFixed(0)}%',
          radius: 55,
          titleStyle: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
        ),
      if (remaining > 0)
        PieChartSectionData(
          value: remaining,
          color: Colors.green.shade500,
          title: '${(remaining / total * 100).toStringAsFixed(0)}%',
          radius: 55,
          titleStyle: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
        ),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            SizedBox(
              height: 160,
              child: PieChart(PieChartData(
                sections: sections,
                centerSpaceRadius: 30,
                sectionsSpace: 2,
              )),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (material > 0)
                  _Legend(color: Colors.orange.shade600,
                      label: 'Material', value: fmtMoney(material)),
                if (labour > 0)
                  _Legend(color: Colors.blue.shade600,
                      label: 'Labour', value: fmtMoney(labour)),
                if (remaining > 0)
                  _Legend(color: Colors.green.shade500,
                      label: 'Remaining', value: fmtMoney(remaining)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MaterialPieChart extends StatelessWidget {
  const _MaterialPieChart({required this.bva});
  final ProjectBva bva;

  static const _palette = [
    Colors.teal,
    Colors.purple,
    Colors.red,
    Colors.amber,
    Colors.cyan,
    Colors.deepOrange,
    Colors.indigo,
    Colors.lime,
  ];

  @override
  Widget build(BuildContext context) {
    final entries = <(String, double)>[
      for (final e in bva.materialByType.entries) (e.key, e.value),
      if (bva.otherMaterial > 0) ('Other', bva.otherMaterial),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();
    final total = entries.fold<double>(0, (a, e) => a + e.$2);

    final sections = entries.asMap().entries.map((entry) {
      final color = _palette[entry.key % _palette.length];
      final pct = (entry.value.$2 / total * 100).toStringAsFixed(0);
      return PieChartSectionData(
        value: entry.value.$2,
        color: color,
        title: '$pct%',
        radius: 55,
        titleStyle: const TextStyle(
            fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white),
      );
    }).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            SizedBox(
              height: 160,
              child: PieChart(PieChartData(
                sections: sections,
                centerSpaceRadius: 30,
                sectionsSpace: 2,
              )),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: entries.asMap().entries.map((entry) {
                final color = _palette[entry.key % _palette.length];
                return _Legend(
                    color: color,
                    label: entry.value.$1,
                    value: fmtMoney(entry.value.$2));
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpendBarChart extends StatelessWidget {
  const _SpendBarChart({required this.daily, required this.period});
  final List<DailySpend> daily;
  final _SpendPeriod period;

  @override
  Widget build(BuildContext context) {
    final bars = _aggregate(daily, period);
    if (bars.isEmpty) {
      return const SizedBox(
        height: 120,
        child: Center(child: Text('No spending data for this project.')),
      );
    }

    final maxY = bars.fold<double>(0, (m, b) => b.$2 > m ? b.$2 : m);
    final periodLabel = switch (period) {
      _SpendPeriod.day => 'per day',
      _SpendPeriod.week => 'per week',
      _SpendPeriod.month => 'per month',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Material + Labour spend, $periodLabel',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 180,
          child: BarChart(
            BarChartData(
              maxY: maxY * 1.25,
              barGroups: bars.asMap().entries.map((e) {
                return BarChartGroupData(
                  x: e.key,
                  barRods: [
                    BarChartRodData(
                      toY: e.value.$2,
                      color: Theme.of(context).colorScheme.primary,
                      width: _barWidth(bars.length),
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(3)),
                    ),
                  ],
                );
              }).toList(),
              titlesData: FlTitlesData(
                bottomTitles: AxisTitles(
                  axisNameWidget: Text(
                    switch (period) {
                      _SpendPeriod.day => 'Date',
                      _SpendPeriod.week => 'Week starting',
                      _SpendPeriod.month => 'Month',
                    },
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  axisNameSize: 16,
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 22,
                    getTitlesWidget: (v, _) {
                      final i = v.toInt();
                      if (i < 0 || i >= bars.length) {
                        return const SizedBox.shrink();
                      }
                      final step = _labelStep(bars.length);
                      if (i % step != 0) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(bars[i].$1,
                            style: const TextStyle(fontSize: 9)),
                      );
                    },
                  ),
                ),
                leftTitles: AxisTitles(
                  axisNameWidget: Text('Spend',
                      style: Theme.of(context).textTheme.labelSmall),
                  axisNameSize: 14,
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 48,
                    interval: _yAxisInterval(maxY),
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
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: _yAxisInterval(maxY),
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
                    '${bars[group.x].$1}\n${fmtMoney(rod.toY)}',
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
    if (count <= 10) return 14;
    if (count <= 20) return 10;
    return 6;
  }

  int _labelStep(int count) {
    if (count <= 10) return 1;
    if (count <= 20) return 2;
    if (count <= 60) return 5;
    return 10;
  }

  /// Picks a "nice" interval (1 / 2 / 2.5 / 5 × 10^n) that keeps the chart
  /// labelled with ~5 horizontal lines regardless of magnitude.
  double _yAxisInterval(double maxY) {
    if (maxY <= 0) return 1;
    final raw = maxY / 4;
    final mag = _magnitude(raw);
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

  double _magnitude(double v) {
    var m = 1.0;
    while (m * 10 <= v) {
      m *= 10;
    }
    while (m > v && m > 1e-9) {
      m /= 10;
    }
    return m;
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label, required this.value});
  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 10,
            height: 10,
            decoration:
                BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            Text(value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Aggregation helpers
// ─────────────────────────────────────────────────────────────────────────────

List<(String label, double amount)> _aggregate(
    List<DailySpend> data, _SpendPeriod period) {
  if (data.isEmpty) return [];

  if (period == _SpendPeriod.day) {
    // Show last 30 days.
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 30));
    return data
        .where((d) => !d.date.isBefore(cutoff))
        .map((d) => ('${d.date.day}/${d.date.month}', d.amount))
        .toList();
  }

  if (period == _SpendPeriod.week) {
    final byWeek = <String, double>{};
    final weekLabel = <String, String>{};
    for (final d in data) {
      final monday = d.date.subtract(Duration(days: d.date.weekday - 1));
      final key = '${monday.year}-${monday.month.toString().padLeft(2, '0')}'
          '-${monday.day.toString().padLeft(2, '0')}';
      byWeek[key] = (byWeek[key] ?? 0) + d.amount;
      weekLabel[key] = '${monday.day}/${monday.month}';
    }
    final sorted = byWeek.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return sorted.map((e) => (weekLabel[e.key]!, e.value)).toList();
  }

  // Month
  const monthAbbr = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final byMonth = <String, double>{};
  for (final d in data) {
    final key = '${d.date.year}-${d.date.month.toString().padLeft(2, '0')}';
    byMonth[key] = (byMonth[key] ?? 0) + d.amount;
  }
  final sorted = byMonth.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  return sorted.map((e) {
    final parts = e.key.split('-');
    final m = int.parse(parts[1]);
    return ('${monthAbbr[m]} ${parts[0].substring(2)}', e.value);
  }).toList();
}

// ─────────────────────────────────────────────────────────────────────────────
// Providers
// ─────────────────────────────────────────────────────────────────────────────

final _bvaProvider =
    FutureProvider.family<ProjectBva, String>((ref, projectId) async {
  ref.watch(ledgerVersionProvider);
  final ledger = await ref.watch(ledgerRepoProvider.future);
  return ledger.projectBva(projectId);
});

final _projectDailySpendProvider =
    FutureProvider.family<List<DailySpend>, String>((ref, projectId) async {
  ref.watch(ledgerVersionProvider);
  final ledger = await ref.watch(ledgerRepoProvider.future);
  return ledger.projectDailySpend(projectId);
});
