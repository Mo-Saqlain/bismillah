import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/models/bank.dart';
import '../../data/repositories/ledger_repository.dart';
import '../../data/sync/sync_service.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';
import '../followups/followups_screen.dart';
import '../home/home_screen.dart' show kPillNavReservedHeight;
import '../reports/bank_ledger_screen.dart';
import '../transactions/transaction_history_screen.dart';
import '../transactions/transaction_picker_screen.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(accountSummaryProvider);
    final banks = ref.watch(banksProvider);
    final recent = ref.watch(recentEntriesProvider);
    final sync = ref.watch(syncStatusProvider);
    final runway = ref.watch(cashRunwayProvider);
    final dailySpend = ref.watch(overallDailySpendProvider);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Bismillah'),
        actions: [
          _SyncIndicator(status: sync),
          const SizedBox(width: 8),
        ],
      ),
      // Reserve space below the FAB so it lifts above the floating
      // pill nav (HomeScreen sets extendBody: true so the body — and
      // therefore the FAB's default position — extends behind the
      // pill). Padding-as-FAB works because Scaffold places the
      // whole widget at endFloat; the bottom margin pushes the FAB
      // up by exactly the pill's reserved height + a small visual
      // gap.
      floatingActionButton: Padding(
        // Lift the FAB a clear gap above the floating pill nav — the old +4
        // left it kissing the pill, worse on tall/gesture-nav phones.
        padding: const EdgeInsets.only(bottom: kPillNavReservedHeight + 20),
        child: FloatingActionButton.extended(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const TransactionPickerScreen()),
          ),
          icon: const Icon(Icons.add),
          label: const Text('New Transaction'),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          bumpLedger(ref);
          await ref
              .read(syncServiceFutureProvider.future)
              .then((s) => s.syncNow());
        },
        child: ListView(
          // Extra bottom padding so the last card can scroll above
          // the floating pill nav + raised FAB instead of being
          // hidden behind them.
          padding: const EdgeInsets.fromLTRB(
            12,
            12,
            12,
            12 + kPillNavReservedHeight + 72,
          ),
          children: [
            // ── Treasury overview ─────────────────────────────────────────
            AsyncView(
              value: summary,
              data: (s) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TreasuryCard(
                    liquidCash: s.liquidCash,
                    netLiquidity: s.netLiquidity,
                    netPosition: s.netPosition,
                    netWorth: s.totalNetWorth,
                    netProfit: s.netProfit,
                    payables: s.payables,
                  ),
                  const SizedBox(height: 8),
                  AsyncView<List<Bank>>(
                    value: banks,
                    data: (banksList) => _WalletGrid(
                      cash: s.cash,
                      banks: banksList,
                      bankBalances: s.bankBalances,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _StatTile(
                          label: 'Payables',
                          value: s.payables,
                          positive: false,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _StatTile(
                          label: 'Receivables',
                          value: s.totalReceivables,
                          positive: true,
                        ),
                      ),
                    ],
                  ),
                  if (s.projectsAtRisk.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _ProjectsAtRiskCard(risks: s.projectsAtRisk),
                  ],
                  if (s.customerDeposits > 0) ...[
                    const SizedBox(height: 8),
                    Card(
                      color: Colors.orange.shade700.withValues(alpha: 0.10),
                      child: ListTile(
                        leading: Icon(
                          Icons.savings_outlined,
                          color: Colors.orange.shade800,
                        ),
                        title: Text(
                          'Customer Deposits (owed back)',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.orange.shade800,
                          ),
                        ),
                        subtitle: const Text(
                          'Money received from customers that hasn’t yet been earned through cost-incurred work.',
                        ),
                        trailing: Text(
                          fmtMoney(s.customerDeposits),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: Colors.orange.shade800,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const _OverdueFollowUpsTile(),
                  if (s.counterReceivables > 0 || s.counterPayables > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _StatTile(
                            label: 'Counter Recv',
                            value: s.counterReceivables,
                            positive: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _StatTile(
                            label: 'Counter Pay',
                            value: s.counterPayables,
                            positive: false,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),

            // ── Cash Runway ───────────────────────────────────────────────
            runway.when(
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
              data: (r) => _CashRunwayCard(runway: r),
            ),

            // ── 7-Day Spending ────────────────────────────────────────────
            const SizedBox(height: 8),
            dailySpend.when(
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
              data: (days) => days.isEmpty
                  ? const SizedBox.shrink()
                  : _DailySpendCard(days: days),
            ),

            const SizedBox(height: 16),

            // ── Recent Activity ───────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Recent Activity',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const TransactionHistoryScreen(),
                    ),
                  ),
                  child: const Text('See all'),
                ),
              ],
            ),
            AsyncView(
              value: recent,
              data: (rows) {
                if (rows.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('No transactions yet — tap + to start.'),
                    ),
                  );
                }
                final seen = <String>{};
                final debitRows = rows
                    .where((e) => e.debit > 0 && seen.add(e.transactionId))
                    .take(8)
                    .toList();
                return Column(
                  children: debitRows.map((e) {
                    return Card(
                      child: ListTile(
                        dense: true,
                        title: Text(fmtMoney(e.debit)),
                        subtitle: Text(
                          e.description ?? fmtDateTime(e.createdAt),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: e.synced == 0
                            ? const Icon(Icons.sync, size: 16)
                            : Icon(
                                Icons.cloud_done,
                                size: 16,
                                color: BalanceColors.positive(context),
                              ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Projects at Risk card — loss-warning panel
// ─────────────────────────────────────────────────────────────────────────────

class _ProjectsAtRiskCard extends StatelessWidget {
  const _ProjectsAtRiskCard({required this.risks});
  final List<ProjectAtRisk> risks;

  @override
  Widget build(BuildContext context) {
    final overCount = risks.where((r) => r.isOverBudget).length;
    final warnCount = risks.length - overCount;
    final headlineColor = overCount > 0
        ? BalanceColors.negative(context)
        : Colors.orange.shade800;

    return Card(
      color:
          (overCount > 0
                  ? BalanceColors.negative(context)
                  : Colors.orange.shade700)
              .withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  overCount > 0
                      ? Icons.error_outline
                      : Icons.warning_amber_outlined,
                  color: headlineColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    overCount > 0
                        ? 'Projects at risk — $overCount over budget'
                              '${warnCount > 0 ? ', $warnCount approaching' : ''}'
                        : '$warnCount project(s) approaching budget',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: headlineColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final r in risks.take(4))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        r.projectName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
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
                            : Colors.orange.shade800,
                      ),
                    ),
                  ],
                ),
              ),
            if (risks.length > 4)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '+ ${risks.length - 4} more',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cash Runway card
// ─────────────────────────────────────────────────────────────────────────────

class _CashRunwayCard extends StatelessWidget {
  const _CashRunwayCard({required this.runway});
  final CashRunway runway;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final String status;
    final IconData icon;

    if (runway.days == null) {
      bg = Theme.of(context).colorScheme.surfaceContainerHighest;
      fg = Theme.of(context).colorScheme.onSurfaceVariant;
      status = 'No spending history yet';
      icon = Icons.hourglass_empty;
    } else if (runway.isGreen) {
      bg = Colors.green.shade700;
      fg = Colors.white;
      status = 'Healthy — 30+ days';
      icon = Icons.check_circle_outline;
    } else if (runway.isYellow) {
      bg = Colors.orange.shade700;
      fg = Colors.white;
      status = 'Caution — 15–30 days';
      icon = Icons.warning_amber_outlined;
    } else {
      bg = Colors.red.shade700;
      fg = Colors.white;
      status = 'Critical — act now';
      icon = Icons.crisis_alert;
    }

    final daysText = runway.days == null
        ? '—'
        : '${runway.days!.toStringAsFixed(1)} days';

    return Card(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: fg, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Cash Runway',
                    style: TextStyle(
                      color: fg,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  Text(
                    daysText,
                    style: TextStyle(
                      color: fg,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                  Text(
                    status,
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.85),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (runway.avgDailyExpense > 0)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Avg daily burn',
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.8),
                      fontSize: 10,
                    ),
                  ),
                  Text(
                    fmtMoney(runway.avgDailyExpense),
                    style: TextStyle(
                      color: fg,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 7-Day Daily Spending bar chart
// ─────────────────────────────────────────────────────────────────────────────

class _DailySpendCard extends StatelessWidget {
  const _DailySpendCard({required this.days});
  final List<DailySpend> days;

  @override
  Widget build(BuildContext context) {
    final maxY = days.fold<double>(0, (m, d) => d.amount > m ? d.amount : m);
    final totalSpend = days.fold<double>(0, (s, d) => s + d.amount);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '7-Day Spending',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  fmtMoney(totalSpend),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: BalanceColors.negative(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 90,
              child: BarChart(
                BarChartData(
                  maxY: maxY * 1.3,
                  barGroups: days.asMap().entries.map((e) {
                    return BarChartGroupData(
                      x: e.key,
                      barRods: [
                        BarChartRodData(
                          toY: e.value.amount,
                          // Peak bar uses the tertiary accent rather than
                          // red — red is reserved strictly for negative
                          // financial values per the design spec.
                          color: e.value.amount == maxY
                              ? Theme.of(context).colorScheme.tertiary
                              : Theme.of(context).colorScheme.primary,
                          width: 22,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(3),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 20,
                        getTitlesWidget: (v, _) {
                          final i = v.toInt();
                          if (i < 0 || i >= days.length) {
                            return const SizedBox.shrink();
                          }
                          final d = days[i].date.toLocal();
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
                    leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  gridData: const FlGridData(show: false),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Material + Labour costs only',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Treasury card — now includes profit vs cash insight
// ─────────────────────────────────────────────────────────────────────────────

class _TreasuryCard extends StatelessWidget {
  const _TreasuryCard({
    required this.liquidCash,
    required this.netLiquidity,
    required this.netPosition,
    required this.netWorth,
    required this.netProfit,
    required this.payables,
  });
  final double liquidCash;
  final double netLiquidity;
  final double netPosition;
  final double netWorth;
  final double netProfit;
  final double payables;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // "Profit Illusion" insight: how much of the cash on hand belongs to
    // future obligations (unpaid payables) rather than real profit.
    final deferredLiability = liquidCash - netProfit;

    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Treasury Overview',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 12),
            // Three derived metrics in one row. Per-account balances (Cash +
            // each bank) live in the Wallets & Banks grid below; their sum is
            // implicit in Net Liquidity / Net Position / Net Worth.
            Row(
              children: [
                _TreasuryCell(
                  label: 'Net Liquidity',
                  value: netLiquidity,
                  onContainer: true,
                ),
                const SizedBox(width: 8),
                _TreasuryCell(
                  label: 'Net Position',
                  value: netPosition,
                  onContainer: true,
                ),
                const SizedBox(width: 8),
                _TreasuryCell(
                  label: 'Net Worth',
                  value: netWorth,
                  onContainer: true,
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),
            // Profit Illusion insight row
            Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 13,
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    deferredLiability > 0
                        ? '${fmtMoney(deferredLiability)} of cash covers costs & payables — real profit is ${fmtMoney(netProfit)}'
                        : 'Net Liquidity = Liquid Cash − Supplier Payables (actual spendable).',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TreasuryCell extends StatelessWidget {
  const _TreasuryCell({
    required this.label,
    required this.value,
    this.onContainer = false,
  });
  final String label;
  final double value;
  final bool onContainer;

  @override
  Widget build(BuildContext context) {
    final color = BalanceColors.signed(context, value);
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: onContainer ? scheme.onPrimaryContainer : scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              fmtSignedMoney(value),
              maxLines: 1,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WalletGrid extends StatelessWidget {
  const _WalletGrid({
    required this.cash,
    required this.banks,
    required this.bankBalances,
  });
  final double cash;
  final List<Bank> banks;
  final Map<String, double> bankBalances;

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      _WalletTile(
        name: 'Cash',
        balance: cash,
        icon: Icons.payments,
        onTap: null,
      ),
      for (final b in banks)
        _WalletTile(
          name: b.name,
          balance: bankBalances[b.id] ?? 0,
          icon: Icons.account_balance,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => BankLedgerScreen(bank: b)),
          ),
        ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Wallets & Banks',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.4,
              children: tiles,
            ),
          ],
        ),
      ),
    );
  }
}

class _WalletTile extends StatelessWidget {
  const _WalletTile({
    required this.name,
    required this.balance,
    required this.icon,
    required this.onTap,
  });
  final String name;
  final double balance;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = BalanceColors.signed(context, balance);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (onTap != null)
                    Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  fmtMoney(balance),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.positive,
  });
  final String label;
  final double value;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final color = positive
        ? BalanceColors.positive(context)
        : BalanceColors.negative(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              fmtMoney(value),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// App-bar sync control. Doubles as a status light and a tap-to-sync
/// button: the icon reflects the live [SyncStatus], and tapping it kicks a
/// forced manual sync (so it works even when background sync is toggled off
/// in Settings). Hidden entirely when Supabase isn't configured in this
/// build — there's nothing to sync to.
class _SyncIndicator extends ConsumerWidget {
  const _SyncIndicator({required this.status});
  final AsyncValue<SyncStatus> status;

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Syncing with Supabase…'),
        duration: Duration(seconds: 1),
      ),
    );
    final svc = await ref.read(syncServiceFutureProvider.future);
    // force: true so a tap still syncs even when the background toggle is off.
    await svc.syncNow(force: true);
    final s = svc.currentStatus;
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(switch (s.state) {
          SyncState.idle => 'Synced ✓',
          SyncState.offline => 'Offline — will sync when back online',
          SyncState.error => 'Sync failed: ${s.message ?? 'unknown error'}',
          _ => 'Sync finished',
        }),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!SupabaseConfig.configured) return const SizedBox.shrink();
    return status.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => IconButton(
        icon: const Icon(Icons.cloud_off),
        tooltip: 'Tap to retry sync',
        onPressed: () => _sync(context, ref),
      ),
      data: (s) {
        final (icon, label) = switch (s.state) {
          SyncState.idle => (Icons.cloud_done, 'Synced'),
          SyncState.syncing => (Icons.cloud_sync, 'Syncing…'),
          SyncState.error => (Icons.cloud_off, 'Sync error'),
          SyncState.offline => (Icons.cloud_off, 'Offline'),
          SyncState.disabled => (Icons.cloud_outlined, 'Local'),
        };
        final syncing = s.state == SyncState.syncing;
        return IconButton(
          tooltip:
              'Sync now · $label${s.pending > 0 ? ' · ${s.pending} pending' : ''}',
          onPressed: syncing ? null : () => _sync(context, ref),
          icon: syncing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon),
        );
      },
    );
  }
}

/// Dashboard tile shown only when there are pending follow-ups. Highlights
/// overdue ones in red. Tap → Recovery Follow-ups screen.
class _OverdueFollowUpsTile extends ConsumerWidget {
  const _OverdueFollowUpsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingFollowUpsProvider);
    return pending.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        final overdue = items.where((f) => f.isOverdue()).toList();
        final hasOverdue = overdue.isNotEmpty;
        final scheme = Theme.of(context).colorScheme;
        return Card(
          color: hasOverdue ? scheme.errorContainer : null,
          child: ListTile(
            leading: Icon(
              hasOverdue ? Icons.warning_amber_rounded : Icons.pending_actions,
              color: hasOverdue
                  ? BalanceColors.negative(context)
                  : scheme.primary,
            ),
            title: Text(
              hasOverdue
                  ? '${overdue.length} overdue follow-up${overdue.length == 1 ? "" : "s"}'
                  : '${items.length} pending follow-up${items.length == 1 ? "" : "s"}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: hasOverdue ? BalanceColors.negative(context) : null,
              ),
            ),
            subtitle: Text(
              hasOverdue
                  ? 'Chase these — promised dates have passed.'
                  : 'Verbal commitments waiting for cash to land.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FollowUpsScreen()),
            ),
          ),
        );
      },
    );
  }
}
