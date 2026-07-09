import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/models/note.dart';
import '../../data/models/project.dart';
import '../../data/repositories/ledger_repository.dart';
import '../../providers/providers.dart';
import '../followups/followups_screen.dart';
import '../notes/notes_panel.dart';
import 'project_reconciliation_screen.dart';

/// Project Snapshot — the "where does this project stand right now?"
/// landing for one project. Surfaces budget vs spend, customer position,
/// projected outcome, the manual completion slider, recovery follow-ups,
/// and notes. Big numbers, minimal clutter — glanceable on a phone.
class SiteSnapshotScreen extends ConsumerWidget {
  const SiteSnapshotScreen({super.key, required this.project});
  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshotAsync = ref.watch(projectSnapshotProvider(project.id));

    return Scaffold(
      appBar: AppBar(
        title: Text(project.name),
        actions: [
          if (!project.archived)
            IconButton(
              tooltip: 'Reconcile & archive',
              icon: const Icon(Icons.balance),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ProjectReconciliationScreen(project: project),
                ),
              ),
            ),
        ],
      ),
      body: snapshotAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load snapshot: $e')),
        data: (s) => ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
          children: [
            _RiskCard(snapshot: s, project: project),
            const SizedBox(height: 12),
            _BigFiguresGrid(snapshot: s),
            const SizedBox(height: 12),
            _CompletionCard(
              project: project,
              snapshot: s,
              onChanged: (v) async {
                final repo = await ref.read(entityRepoProvider.future);
                await repo.updateProjectCompletion(project.id, v);
                bumpLedger(ref);
              },
            ),
            const SizedBox(height: 12),
            _ForecastCard(snapshot: s),
            const SizedBox(height: 12),
            _OutstandingCard(snapshot: s),
            const SizedBox(height: 12),
            _ProjectFollowUpsTile(projectId: project.id),
            const SizedBox(height: 12),
            NotesPanel(
              entityType: NoteEntityType.project,
              entityId: project.id,
              title: 'Project notes',
            ),
          ],
        ),
      ),
    );
  }
}

/// Headline color-coded banner. The risk band comes from
/// [ProjectSnapshot.riskBand].
class _RiskCard extends StatelessWidget {
  const _RiskCard({required this.snapshot, required this.project});
  final ProjectSnapshot snapshot;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg, String label, IconData icon) =
        switch (snapshot.riskBand) {
      'red' => (
        scheme.errorContainer,
        BalanceColors.negative(context),
        'On track for a loss',
        Icons.warning_amber_rounded
      ),
      'amber' => (
        Colors.amber.shade100,
        Colors.amber.shade900,
        'Approaching budget',
        Icons.flag_circle
      ),
      _ => (
        scheme.primaryContainer,
        BalanceColors.positive(context),
        'On budget',
        Icons.check_circle
      ),
    };

    return Card(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: fg, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: fg,
                          )),
                  const SizedBox(height: 4),
                  Text(
                    project.model.label +
                        (project.archived ? ' · ARCHIVED' : ''),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${snapshot.pctOfBudgetConsumed.toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                ),
                Text('of budget',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 2x2 grid of headline figures: Budget, Received, Spent, Profit-so-far.
class _BigFiguresGrid extends StatelessWidget {
  const _BigFiguresGrid({required this.snapshot});
  final ProjectSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.6,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        _BigFigure(
            label: 'Budget',
            value: fmtMoney(snapshot.budget),
            icon: Icons.flag_outlined),
        _BigFigure(
            label: 'Received',
            value: fmtMoney(snapshot.received),
            icon: Icons.south_west),
        _BigFigure(
            label: 'Spent',
            value: fmtMoney(snapshot.spent),
            icon: Icons.north_east),
        _BigFigure(
          label: 'Profit so far',
          value: fmtSignedMoney(snapshot.realizedProfit),
          icon: Icons.trending_up,
          colorize: snapshot.realizedProfit,
        ),
      ],
    );
  }
}

class _BigFigure extends StatelessWidget {
  const _BigFigure({
    required this.label,
    required this.value,
    required this.icon,
    this.colorize,
  });
  final String label;
  final String value;
  final IconData icon;
  final double? colorize;

  @override
  Widget build(BuildContext context) {
    final color = colorize == null
        ? null
        : BalanceColors.signed(context, colorize!);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(icon,
                    size: 16,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.55)),
                const SizedBox(width: 6),
                Text(label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.65),
                        )),
              ],
            ),
            const Spacer(),
            Text(value,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: color,
                    )),
          ],
        ),
      ),
    );
  }
}

/// Manual completion slider — owner-entered rough %. The slider's onChanged
/// only updates local UI state; commits go on `onChangeEnd` to avoid one
/// SQL write per drag pixel.
class _CompletionCard extends ConsumerStatefulWidget {
  const _CompletionCard({
    required this.project,
    required this.snapshot,
    required this.onChanged,
  });
  final Project project;
  final ProjectSnapshot snapshot;
  final ValueChanged<int> onChanged;

  @override
  ConsumerState<_CompletionCard> createState() => _CompletionCardState();
}

class _CompletionCardState extends ConsumerState<_CompletionCard> {
  double? _pending;

  @override
  Widget build(BuildContext context) {
    final value =
        (_pending ?? widget.project.completionPercent.toDouble()).clamp(0, 100);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Manual completion',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          )),
                ),
                Text('${value.toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        )),
              ],
            ),
            Slider(
              value: value.toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              label: '${value.toStringAsFixed(0)}%',
              onChanged: widget.project.archived
                  ? null
                  : (v) => setState(() => _pending = v),
              onChangeEnd: widget.project.archived
                  ? null
                  : (v) {
                      widget.onChanged(v.round());
                      setState(() => _pending = null);
                    },
            ),
            Text(
              'Owner-entered estimate — used to forecast the projected cost '
              'to complete and the final P&L.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ForecastCard extends StatelessWidget {
  const _ForecastCard({required this.snapshot});
  final ProjectSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Projected outcome',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    )),
            const SizedBox(height: 8),
            _Row(
                label: 'Cost still to incur',
                value: snapshot.projectedRemainingCost),
            _Row(
                label: 'Receivable still expected',
                value: snapshot.projectedReceivable),
            _Row(
              label: snapshot.projectedCashGap >= 0
                  ? 'Cash gap to bridge'
                  : 'Projected surplus',
              value: snapshot.projectedCashGap.abs(),
              colorize: snapshot.projectedCashGap,
            ),
            const Divider(),
            _Row(
              label: 'Projected profit at close',
              value: snapshot.projectedFinalProfit,
              colorize: snapshot.projectedFinalProfit,
              bold: true,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                snapshot.completionPercent == 0
                    ? 'No completion% set — forecast falls back to '
                        'budget headroom. Slide the completion % above for a '
                        'better estimate.'
                    : 'Forecast based on linear extrapolation from your '
                        '${snapshot.completionPercent}% completion estimate.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutstandingCard extends StatelessWidget {
  const _OutstandingCard({required this.snapshot});
  final ProjectSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Outstanding positions',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    )),
            const SizedBox(height: 8),
            _Row(
              label: 'Supplier payables open',
              value: snapshot.supplierPayables,
              colorize: -snapshot.supplierPayables,
            ),
            _Row(
              label: 'Customer deposit (cash trapped)',
              value: snapshot.customerDeposit,
            ),
            _Row(
              label: 'Service fee booked',
              value: snapshot.serviceFeeBooked,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectFollowUpsTile extends ConsumerWidget {
  const _ProjectFollowUpsTile({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingAsync = ref.watch(pendingFollowUpsProvider);
    return pendingAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (all) {
        final mine = all.where((f) => f.projectId == projectId).toList();
        if (mine.isEmpty) return const SizedBox.shrink();
        final overdueCount = mine.where((f) => f.isOverdue()).length;
        return Card(
          color: overdueCount > 0
              ? Theme.of(context).colorScheme.errorContainer
              : null,
          child: ListTile(
            leading: Icon(
              overdueCount > 0
                  ? Icons.warning_amber_rounded
                  : Icons.pending_actions,
              color: overdueCount > 0
                  ? BalanceColors.negative(context)
                  : Theme.of(context).colorScheme.primary,
            ),
            title: Text(
              overdueCount > 0
                  ? '${mine.length} follow-up${mine.length == 1 ? "" : "s"} — '
                      '$overdueCount overdue'
                  : '${mine.length} pending follow-up${mine.length == 1 ? "" : "s"}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(mine.first.title),
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

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.colorize,
    this.bold = false,
  });
  final String label;
  final double value;
  final double? colorize;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final color = colorize == null
        ? null
        : BalanceColors.signed(context, colorize!);
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
      color: color,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(fmtSignedMoney(value), style: style),
        ],
      ),
    );
  }
}
