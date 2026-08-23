import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/formatters.dart';
import 'package:bismillah_constructions/shared/core/theme.dart';
import 'package:bismillah_constructions/shared/data/models/bank.dart';
import 'package:bismillah_constructions/shared/data/repositories/ledger_repository.dart'
    show DailySpend, ProjectAtRisk;
import 'package:bismillah_constructions/shared/providers/providers.dart';
import 'package:bismillah_constructions/desktop/desktop_theme.dart';
import 'package:bismillah_constructions/mobile/features/reports/payables_receivables_screen.dart';


/// Wide desktop dashboard. Reuses the shared providers (so numbers agree
/// with the mobile app and every report) but lays them out for a large
/// screen and adds charts the phone dashboard doesn't have: a cash
/// distribution pie, an assets-vs-liabilities bar, and an income-vs-costs
/// P&L bar.
class DashboardTab extends ConsumerWidget {
  const DashboardTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(accountSummaryProvider);
    final banksAsync = ref.watch(banksProvider);
    final runway = ref.watch(cashRunwayProvider);
    final dailySpend = ref.watch(overallDailySpendProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: RefreshIndicator(
        onRefresh: () async => bumpLedger(ref),
        child: summaryAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Failed to load: $e')),
          data: (s) {
            final banks = banksAsync.asData?.value ?? const <Bank>[];
            return LayoutBuilder(
              builder: (context, c) {
                // Two chart columns on wide windows, one when narrow.
                final wide = c.maxWidth >= 900;
                final chartWidth =
                    wide ? (c.maxWidth - 24 - 48) / 2 : c.maxWidth - 48;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
                  children: [
                    Text('Dashboard',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onSurface,
                        )),
                    const SizedBox(height: 4),
                    Text('Live financial position across all projects.',
                        style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 18),

                    // ── KPI strip ─────────────────────────────────────────
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _Kpi(label: 'Liquid Cash', value: s.liquidCash),
                        _Kpi(label: 'Net Liquidity', value: s.netLiquidity),
                        _Kpi(label: 'Net Worth', value: s.totalNetWorth),
                        _Kpi(label: 'Net Profit', value: s.netProfit),
                        _Kpi(
                          label: 'Payables',
                          value: s.payables,
                          negativeTint: true,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const PayablesReceivablesScreen()),
                          ),
                        ),
                        _Kpi(
                          label: 'Receivables',
                          value: s.totalReceivables,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const PayablesReceivablesScreen()),
                          ),
                        ),
                        if (s.customerDeposits > 0)
                          _Kpi(
                              label: 'Customer Deposits',
                              value: s.customerDeposits,
                              negativeTint: true),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Charts ────────────────────────────────────────────
                    Wrap(
                      spacing: 24,
                      runSpacing: 24,
                      children: [
                        SizedBox(
                          width: chartWidth,
                          child: _CashDistributionCard(
                              cash: s.cash, banks: banks, balances: s.bankBalances),
                        ),
                        SizedBox(
                          width: chartWidth,
                          child: _AssetsLiabilitiesCard(summary: s),
                        ),
                        SizedBox(
                          width: chartWidth,
                          child: _IncomeVsCostsCard(summary: s),
                        ),
                        SizedBox(
                          width: chartWidth,
                          child: dailySpend.when(
                            loading: () => const _ChartShell(
                                title: '7-Day Spending',
                                child: Center(child: CircularProgressIndicator())),
                            error: (_, _) => const SizedBox.shrink(),
                            data: (days) => _SpendingCard(days: days),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Runway + at-risk ──────────────────────────────────
                    runway.when(
                      loading: () => const SizedBox.shrink(),
                      error: (_, _) => const SizedBox.shrink(),
                      data: (r) => _RunwayBar(
                          days: r.days,
                          avg: r.avgDailyExpense,
                          green: r.isGreen,
                          yellow: r.isYellow),
                    ),
                    if (s.projectsAtRisk.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _AtRiskCard(risks: s.projectsAtRisk),
                    ],
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

// ── KPI tile ────────────────────────────────────────────────────────────────

class _Kpi extends StatelessWidget {
  const _Kpi({
    required this.label,
    required this.value,
    this.negativeTint = false,
    this.onTap,
  });
  final String label;
  final double value;
  final bool negativeTint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = negativeTint
        ? BalanceColors.negative(context)
        : BalanceColors.signed(context, value);
    Widget content = Container(
      width: 196,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(DesktopRadii.medium),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: scheme.onSurfaceVariant,
                    )),
              ),
              if (onTap != null)
                Icon(Icons.open_in_new, size: 12, color: scheme.onSurfaceVariant),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(fmtMoney(value),
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800, color: color)),
          ),
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DesktopRadii.medium),
        child: content,
      );
    }
    return content;
  }
}

// ── Chart shell ──────────────────────────────────────────────────────────────

class _ChartShell extends StatelessWidget {
  const _ChartShell({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(DesktopRadii.medium),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(height: 200, child: child),
        ],
      ),
    );
  }
}

// ── Cash distribution pie ────────────────────────────────────────────────────

class _CashDistributionCard extends StatelessWidget {
  const _CashDistributionCard(
      {required this.cash, required this.banks, required this.balances});
  final double cash;
  final List<Bank> banks;
  final Map<String, double> balances;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = <(String, double)>[
      ('Cash', cash),
      for (final b in banks) (b.name, balances[b.id] ?? 0),
    ].where((e) => e.$2 > 0).toList();
    final total = entries.fold<double>(0, (a, e) => a + e.$2);

    final palette = <Color>[
      scheme.primary,
      scheme.tertiary,
      const Color(0xFF059669),
      const Color(0xFFD97706),
      const Color(0xFF7C3AED),
      const Color(0xFF0891B2),
      const Color(0xFFBE185D),
    ];

    if (entries.isEmpty || total <= 0) {
      return const _ChartShell(
        title: 'Cash Distribution',
        child: Center(child: Text('No positive balances yet.')),
      );
    }

    return _ChartShell(
      title: 'Cash Distribution',
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: PieChart(
              PieChartData(
                sectionsSpace: 2,
                centerSpaceRadius: 34,
                sections: [
                  for (var i = 0; i < entries.length; i++)
                    PieChartSectionData(
                      value: entries[i].$2,
                      color: palette[i % palette.length],
                      title: '${(entries[i].$2 / total * 100).round()}%',
                      radius: 52,
                      titleStyle: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < entries.length && i < 7; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: palette[i % palette.length],
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(entries[i].$1,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12)),
                        ),
                        Text(fmtCompactMoney(entries[i].$2),
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Assets vs Liabilities ────────────────────────────────────────────────────

class _AssetsLiabilitiesCard extends StatelessWidget {
  const _AssetsLiabilitiesCard({required this.summary});
  final AccountSummary summary;

  @override
  Widget build(BuildContext context) {
    final assets = summary.liquidCash +
        summary.counterReceivables +
        summary.totalReceivables;
    final liabilities = summary.payables +
        summary.counterPayables +
        summary.customerDeposits;
    final maxV = [assets, liabilities, 1.0].reduce((a, b) => a > b ? a : b);
    final pos = BalanceColors.positive(context);
    final neg = BalanceColors.negative(context);

    return _ChartShell(
      title: 'Assets vs Liabilities',
      child: BarChart(
        BarChartData(
          maxY: maxV * 1.25,
          alignment: BarChartAlignment.spaceEvenly,
          barGroups: [
            _bar(0, assets, pos),
            _bar(1, liabilities, neg),
          ],
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                getTitlesWidget: (v, _) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(v == 0 ? 'Assets' : 'Liabilities',
                      style: const TextStyle(fontSize: 11)),
                ),
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          gridData: const FlGridData(show: false),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (g, gi, r, ri) => BarTooltipItem(
                  fmtMoney(r.toY), const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ),
        ),
      ),
    );
  }

  BarChartGroupData _bar(int x, double y, Color color) => BarChartGroupData(
        x: x,
        barRods: [
          BarChartRodData(
            toY: y,
            color: color,
            width: 46,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
          ),
        ],
      );
}

// ── Income vs Costs ──────────────────────────────────────────────────────────

class _IncomeVsCostsCard extends StatelessWidget {
  const _IncomeVsCostsCard({required this.summary});
  final AccountSummary summary;

  @override
  Widget build(BuildContext context) {
    final income = summary.revenue + summary.serviceFeeIncome;
    final costs = summary.materialCosts +
        summary.labourCosts +
        summary.personalDraw +
        summary.lossProvision;
    final maxV = [income, costs, 1.0].reduce((a, b) => a > b ? a : b);
    final scheme = Theme.of(context).colorScheme;

    return _ChartShell(
      title: 'Income vs Costs (recognized)',
      trailing: Text('Net ${fmtSignedMoney(income - costs)}',
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: BalanceColors.signed(context, income - costs))),
      child: BarChart(
        BarChartData(
          maxY: maxV * 1.25,
          alignment: BarChartAlignment.spaceEvenly,
          barGroups: [
            _bar(0, income, scheme.primary),
            _bar(1, costs, scheme.tertiary),
          ],
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                getTitlesWidget: (v, _) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(v == 0 ? 'Income' : 'Costs',
                      style: const TextStyle(fontSize: 11)),
                ),
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          gridData: const FlGridData(show: false),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (g, gi, r, ri) => BarTooltipItem(
                  fmtMoney(r.toY), const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ),
        ),
      ),
    );
  }

  BarChartGroupData _bar(int x, double y, Color color) => BarChartGroupData(
        x: x,
        barRods: [
          BarChartRodData(
            toY: y,
            color: color,
            width: 46,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
          ),
        ],
      );
}

// ── Spending bar ─────────────────────────────────────────────────────────────

class _SpendingCard extends StatelessWidget {
  const _SpendingCard({required this.days});
  final List<DailySpend> days;

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) {
      return const _ChartShell(
          title: '7-Day Spending',
          child: Center(child: Text('No spending recorded yet.')));
    }
    final maxY = days.fold<double>(0, (m, d) => d.amount > m ? d.amount : m);
    final total = days.fold<double>(0, (s, d) => s + d.amount);
    final scheme = Theme.of(context).colorScheme;

    return _ChartShell(
      title: '7-Day Spending',
      trailing: Text(fmtMoney(total),
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: BalanceColors.negative(context))),
      child: BarChart(
        BarChartData(
          maxY: maxY * 1.3 + 1,
          barGroups: days.asMap().entries.map((e) {
            return BarChartGroupData(x: e.key, barRods: [
              BarChartRodData(
                toY: e.value.amount,
                color: e.value.amount == maxY ? scheme.tertiary : scheme.primary,
                width: 20,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
              ),
            ]);
          }).toList(),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                getTitlesWidget: (v, _) {
                  final i = v.toInt();
                  if (i < 0 || i >= days.length) return const SizedBox.shrink();
                  final d = days[i].date.toLocal();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${d.day}/${d.month}',
                        style: const TextStyle(fontSize: 9)),
                  );
                },
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          gridData: const FlGridData(show: false),
        ),
      ),
    );
  }
}

// ── Cash runway bar ──────────────────────────────────────────────────────────

class _RunwayBar extends StatelessWidget {
  const _RunwayBar(
      {required this.days,
      required this.avg,
      required this.green,
      required this.yellow});
  final double? days;
  final double avg;
  final bool green;
  final bool yellow;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final String status;
    final IconData icon;
    if (days == null) {
      bg = Theme.of(context).colorScheme.surfaceContainerHighest;
      status = 'No spending history yet';
      icon = Icons.hourglass_empty;
    } else if (green) {
      bg = const Color(0xFF15803D);
      status = 'Healthy — 30+ days';
      icon = Icons.check_circle_outline;
    } else if (yellow) {
      bg = const Color(0xFFB45309);
      status = 'Caution — 15–30 days';
      icon = Icons.warning_amber_outlined;
    } else {
      bg = const Color(0xFFB91C1C);
      status = 'Critical — act now';
      icon = Icons.crisis_alert;
    }
    final fg = days == null
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : Colors.white;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(DesktopRadii.medium),
      ),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 30),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('CASH RUNWAY',
                  style: TextStyle(
                      color: fg,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6)),
              Text(days == null ? '—' : '${days!.toStringAsFixed(1)} days',
                  style: TextStyle(
                      color: fg, fontSize: 24, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(width: 18),
          Text(status, style: TextStyle(color: fg.withValues(alpha: 0.9))),
          const Spacer(),
          if (avg > 0)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Avg daily burn',
                    style: TextStyle(
                        color: fg.withValues(alpha: 0.85), fontSize: 11)),
                Text(fmtMoney(avg),
                    style: TextStyle(
                        color: fg, fontSize: 15, fontWeight: FontWeight.w700)),
              ],
            ),
        ],
      ),
    );
  }
}

// ── Projects at risk ─────────────────────────────────────────────────────────

class _AtRiskCard extends StatelessWidget {
  const _AtRiskCard({required this.risks});
  final List<ProjectAtRisk> risks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final over = risks.where((r) => r.isOverBudget).length;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(DesktopRadii.medium),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: BalanceColors.negative(context), size: 20),
              const SizedBox(width: 8),
              Text(
                over > 0
                    ? 'Projects at risk — $over over budget'
                    : '${risks.length} project(s) approaching budget',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final r in risks.take(8))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(r.projectName,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Text(
                    r.isOverBudget
                        ? 'over by ${fmtMoney(r.costsToDate - r.budget)}'
                        : '${r.pctConsumed.toStringAsFixed(0)}% used',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: r.isOverBudget
                          ? BalanceColors.negative(context)
                          : const Color(0xFFB45309),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
