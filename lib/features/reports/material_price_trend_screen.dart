import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/repositories/ledger_repository.dart';
import '../../providers/providers.dart';

/// Per-material unit-price chart, sourced from every
/// `material_inventory.rate` recorded over the selected window.
///
/// Designed for the "what should I quote next time?" question. Each
/// material category becomes a line; the X axis is time, Y axis is the
/// unit price recorded at each purchase. The user picks the look-back
/// window (3 / 6 / 12 months) and a single material from a dropdown so
/// the chart isn't a tangle when many categories are tracked.
class MaterialPriceTrendScreen extends ConsumerStatefulWidget {
  const MaterialPriceTrendScreen({super.key});

  @override
  ConsumerState<MaterialPriceTrendScreen> createState() =>
      _MaterialPriceTrendScreenState();
}

enum _Window { months3, months6, months12 }

class _MaterialPriceTrendScreenState
    extends ConsumerState<MaterialPriceTrendScreen> {
  _Window _window = _Window.months6;
  String? _materialFilter;

  int get _monthsBack => switch (_window) {
        _Window.months3 => 3,
        _Window.months6 => 6,
        _Window.months12 => 12,
      };

  @override
  Widget build(BuildContext context) {
    ref.watch(ledgerVersionProvider);
    final dataAsync = ref.watch(_priceTrendProvider(_monthsBack));

    return Scaffold(
      appBar: AppBar(title: const Text('Material Price Trend')),
      body: dataAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (byMaterial) {
          if (byMaterial.isEmpty) {
            return const _Empty();
          }
          // Default to the material with the most data points so the
          // first render has something interesting on screen.
          _materialFilter ??= _pickDefaultMaterial(byMaterial);
          final selected = _materialFilter;
          final selectedPoints = selected != null
              ? (byMaterial[selected] ?? const <PricePoint>[])
              : const <PricePoint>[];

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              // Window toggle
              SegmentedButton<_Window>(
                segments: const [
                  ButtonSegment(value: _Window.months3, label: Text('3 mo')),
                  ButtonSegment(value: _Window.months6, label: Text('6 mo')),
                  ButtonSegment(value: _Window.months12, label: Text('12 mo')),
                ],
                selected: {_window},
                onSelectionChanged: (s) =>
                    setState(() => _window = s.first),
              ),
              const SizedBox(height: 12),

              // Material picker
              DropdownButtonFormField<String>(
                initialValue: selected,
                decoration: const InputDecoration(
                  labelText: 'Material',
                  border: OutlineInputBorder(),
                ),
                items: byMaterial.keys
                    .map((k) => DropdownMenuItem(
                          value: k,
                          child:
                              Text('$k  (${byMaterial[k]!.length} entries)'),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _materialFilter = v),
              ),

              const SizedBox(height: 16),

              // Stats card
              if (selectedPoints.isNotEmpty)
                _StatsCard(material: selected!, points: selectedPoints),
              const SizedBox(height: 12),

              // Chart card
              if (selectedPoints.length >= 2)
                _TrendCard(material: selected!, points: selectedPoints)
              else if (selectedPoints.length == 1)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                        'Only one purchase recorded for this material in '
                        'the window — need at least two data points to '
                        'plot a trend.'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Pick the material with the most price points in the window. Ties
  /// broken alphabetically for stable UI.
  String _pickDefaultMaterial(Map<String, List<PricePoint>> byMaterial) {
    final entries = byMaterial.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.length.compareTo(a.value.length);
        if (byCount != 0) return byCount;
        return a.key.compareTo(b.key);
      });
    return entries.first.key;
  }
}

// ─── Empty state ────────────────────────────────────────────────────────

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.show_chart,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            const Text('No material purchases yet.',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'Buy material with a quantity to start tracking unit-price '
              'changes here.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Stats summary ──────────────────────────────────────────────────────

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.material, required this.points});
  final String material;
  final List<PricePoint> points;

  @override
  Widget build(BuildContext context) {
    final first = points.first;
    final last = points.last;
    final rates = points.map((p) => p.rate).toList()..sort();
    final min = rates.first;
    final max = rates.last;
    final avg = rates.fold<double>(0, (a, b) => a + b) / rates.length;
    final delta = last.rate - first.rate;
    final pctChange = first.rate == 0 ? 0.0 : (delta / first.rate * 100);
    final isUp = delta > 0;

    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(material,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
                'First seen ${fmtDate(first.date)} · '
                'last seen ${fmtDate(last.date)} · '
                '${points.length} purchases',
                style: Theme.of(context).textTheme.bodySmall),
            const Divider(),
            Row(children: [
              _Stat(label: 'Min', value: fmtMoney(min)),
              _Stat(label: 'Avg', value: fmtMoney(avg)),
              _Stat(label: 'Max', value: fmtMoney(max)),
              _Stat(label: 'Latest', value: fmtMoney(last.rate)),
            ]),
            const SizedBox(height: 12),
            if (points.length >= 2)
              Row(
                children: [
                  Icon(
                      isUp
                          ? Icons.trending_up
                          : (delta < 0
                              ? Icons.trending_down
                              : Icons.trending_flat),
                      color: isUp ? scheme.error : scheme.primary),
                  const SizedBox(width: 8),
                  Text(
                      isUp
                          ? 'Price rose by ${fmtMoney(delta.abs())} '
                              '(${pctChange.toStringAsFixed(1)}%) since the first purchase'
                          : delta < 0
                              ? 'Price fell by ${fmtMoney(delta.abs())} '
                                  '(${pctChange.abs().toStringAsFixed(1)}%) since the first purchase'
                              : 'Price has stayed flat',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
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
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 14)),
        ],
      ),
    );
  }
}

// ─── Trend chart ─────────────────────────────────────────────────────────

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.material, required this.points});
  final String material;
  final List<PricePoint> points;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final values = points.map((p) => p.rate).toList();
    final minY = values.reduce((a, b) => a < b ? a : b);
    final maxY = values.reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY) * 0.15;
    final lowY = (minY - pad).clamp(0, double.infinity).toDouble();
    final highY = maxY + pad;

    // Use index for X so points are evenly spaced regardless of the
    // calendar gaps between purchases — the trend is what matters, not
    // the precise X-axis position.
    final spots = <FlSpot>[
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), points[i].rate)
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Unit price over time',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
                'Each dot = one purchase. Spaced evenly along X — gaps '
                'between purchases not to scale.',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              child: LineChart(LineChartData(
                minY: lowY,
                maxY: highY,
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    color: scheme.primary,
                    barWidth: 2.5,
                    isCurved: false,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, _, _, _) => FlDotCirclePainter(
                        radius: 3.5,
                        color: scheme.primary,
                        strokeColor: scheme.surface,
                        strokeWidth: 1.5,
                      ),
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      color: scheme.primary.withValues(alpha: 0.08),
                    ),
                  ),
                ],
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    axisNameWidget: Text('Purchase order',
                        style: Theme.of(context).textTheme.labelSmall),
                    axisNameSize: 14,
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: _xInterval(points.length).toDouble(),
                      getTitlesWidget: (v, _) {
                        final i = v.toInt();
                        if (i < 0 || i >= points.length) {
                          return const SizedBox.shrink();
                        }
                        final d = points[i].date.toLocal();
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${d.day}/${d.month}',
                            style: const TextStyle(fontSize: 9),
                          ),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    axisNameWidget: Text('Unit price',
                        style: Theme.of(context).textTheme.labelSmall),
                    axisNameSize: 14,
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
                      final p = points[s.spotIndex];
                      return LineTooltipItem(
                        '${fmtDate(p.date)}\n${fmtMoney(p.rate)}',
                        const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 11),
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

  int _xInterval(int count) {
    if (count <= 6) return 1;
    if (count <= 12) return 2;
    if (count <= 30) return 5;
    return 10;
  }
}

// ─── Provider ───────────────────────────────────────────────────────────

final _priceTrendProvider = FutureProvider.family<
    Map<String, List<PricePoint>>, int>((ref, monthsBack) async {
  ref.watch(ledgerVersionProvider);
  final ledger = await ref.watch(ledgerRepoProvider.future);
  return ledger.priceTrend(monthsBack: monthsBack);
});
