import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/models/project.dart';
import '../../data/repositories/ledger_repository.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';
import '../common/date_range_bar.dart';
import '../../core/export/csv_export.dart';
import '../../core/export/pdf_generator.dart';

class IncomeStatementScreen extends ConsumerStatefulWidget {
  const IncomeStatementScreen({super.key});

  @override
  ConsumerState<IncomeStatementScreen> createState() =>
      _IncomeStatementScreenState();
}

class _IncomeStatementScreenState
    extends ConsumerState<IncomeStatementScreen> {
  String? _projectId; // null = all projects
  DateTime? _from;
  DateTime? _to;

  /// Bundles the headline PoC P&L from [LedgerRepository.incomeFigures]
  /// with the two breakdowns (material by type, labour by supplier) plus
  /// a supplier name lookup so the screen can render real names instead
  /// of UUIDs.
  Future<_DetailedFigures> _figures(WidgetRef ref) async {
    final repo = await ref.read(ledgerRepoProvider.future);
    final entityRepo = await ref.read(entityRepoProvider.future);

    final figures = await repo.incomeFigures(
      from: _from,
      to: _to,
      projectId: _projectId,
    );
    final mat = await repo.materialCostsByType(
      from: _from,
      to: _to,
      projectId: _projectId,
    );
    final lab = await repo.labourCostsBySupplier(
      from: _from,
      to: _to,
      projectId: _projectId,
    );

    // Map supplier ids to display names. Include archived suppliers so
    // older transactions still resolve to a real label.
    final active = await entityRepo.suppliers();
    final archived = await entityRepo.archivedSuppliers();
    final nameMap = <String, String>{
      for (final s in [...active, ...archived]) s.id: s.name,
    };

    return _DetailedFigures(
      figures: figures,
      materialByType: mat.byType,
      materialUntracked: mat.untracked,
      labourBySupplier: lab,
      supplierNames: nameMap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final projects = ref.watch(projectsProvider);
    // re-trigger figures whenever ledger version, project filter or
    // date window changes.
    final version = ref.watch(ledgerVersionProvider);
    final figuresFuture = _figures(ref);

    return Scaffold(
      appBar: AppBar(title: const Text('Income Statement')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DateRangeBar(
            from: _from,
            to: _to,
            onChanged: (f, t) => setState(() {
              _from = f;
              _to = t;
            }),
          ),
          const SizedBox(height: 12),
          AsyncView<List<Project>>(
            value: projects,
            data: (list) => DropdownButtonFormField<String?>(
              initialValue: _projectId,
              decoration: const InputDecoration(labelText: 'Filter by Project'),
              items: [
                const DropdownMenuItem<String?>(
                    value: null, child: Text('All projects')),
                ...list.map((p) => DropdownMenuItem<String?>(
                    value: p.id, child: Text(p.name))),
              ],
              onChanged: (v) => setState(() => _projectId = v),
            ),
          ),
          const SizedBox(height: 16),
          FutureBuilder<_DetailedFigures>(
            key: ValueKey(
                '$_projectId-$version-${_from?.toIso8601String()}-${_to?.toIso8601String()}'),
            future: figuresFuture,
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final d = snap.data!;
              final f = d.figures;
              final totalIncome = f.totalIncome;
              final totalCosts = f.totalCosts;
              final net = f.netProfit;
              final totalDeposit = f.totalDeposit;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('Period: ${formatPeriod(_from, _to)}',
                        style: Theme.of(ctx).textTheme.bodySmall),
                  ),
                  if (f.projectsAtRisk.isNotEmpty)
                    _AtRiskBanner(risks: f.projectsAtRisk),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // ── Income ──────────────────────────────────────
                          if (f.wmRevenue > 0)
                            _row(context, 'Contract Revenue (With-Material)',
                                f.wmRevenue),
                          if (f.serviceFees > 0)
                            _row(context, 'Service Fees', f.serviceFees),
                          _row(context, 'Total Income', totalIncome,
                              bold: true),
                          const Divider(),
                          // ── Costs ────────────────────────────────────────
                          _row(context, 'Material Costs', -f.matCosts,
                              bold: true),
                          // Material breakdown: one sub-line per type,
                          // plus an "Untracked" line for material spend
                          // that hit Material Costs in the journal but
                          // doesn't have a matching material_inventory
                          // row (legacy / direct posts).
                          ..._sortedByValueDesc(d.materialByType).map((e) =>
                              _row(context, '    ${e.key}', -e.value)),
                          if (d.materialUntracked > 0)
                            _row(context,
                                '    Untracked (no inventory row)',
                                -d.materialUntracked),
                          _row(context, 'Labour Costs', -f.labCosts,
                              bold: true),
                          // Labour breakdown by worker. Skip when no
                          // entries — keeps the report tight on
                          // material-only projects.
                          ..._sortedByValueDesc(d.labourBySupplier)
                              .map((e) => _row(
                                  context,
                                  '    ${d.supplierNames[e.key] ?? e.key.substring(0, e.key.length.clamp(0, 8))}',
                                  -e.value)),
                          if (f.personalDraw > 0)
                            _row(context, 'Personal Draw', -f.personalDraw),
                          if (f.lossProvision > 0)
                            _row(context, 'Loss Provision (over-budget jobs)',
                                -f.lossProvision,
                                color: BalanceColors.negative(context)),
                          _row(context, 'Total Costs', -totalCosts,
                              bold: true),
                          const Divider(),
                          _row(context, 'Net Profit / (Loss)', net,
                              bold: true,
                              color: BalanceColors.signed(context, net)),
                          // ── Customer Deposits (informational) ───────────
                          if (totalDeposit > 0) ...[
                            const SizedBox(height: 12),
                            const Divider(),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              child: Text(
                                  'Customer Deposits (owed back)',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelLarge
                                      ?.copyWith(
                                          color: Colors.orange.shade700)),
                            ),
                            if (f.lrDeposit > 0)
                              _row(context, '  Labour-Rate projects',
                                  -f.lrDeposit,
                                  color: Colors.orange.shade700),
                            if (f.wmDeposit > 0)
                              _row(context, '  Unearned (With-Material)',
                                  -f.wmDeposit,
                                  color: Colors.orange.shade700),
                            _row(context, '  Total deposits owed',
                                -totalDeposit,
                                bold: true, color: Colors.orange.shade700),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.picture_as_pdf),
                        label: const Text('PDF'),
                        onPressed: () async {
                          String? name;
                          if (_projectId != null) {
                            final repo =
                                await ref.read(entityRepoProvider.future);
                            name = (await repo.project(_projectId!))?.name;
                          }
                          await PdfGenerator.previewIncomeStatement(
                            IncomeStatementData(
                              projectName: name,
                              wmRevenue: f.wmRevenue,
                              serviceFees: f.serviceFees,
                              materialCosts: f.matCosts,
                              labourCosts: f.labCosts,
                              personalDraw: f.personalDraw,
                              lrDeposit: f.lrDeposit,
                              wmDeposit: f.wmDeposit,
                              generatedAt: DateTime.now(),
                              period: formatPeriod(_from, _to),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.file_download),
                        label: const Text('CSV'),
                        onPressed: () async {
                          String? name = 'All projects';
                          if (_projectId != null) {
                            final repo =
                                await ref.read(entityRepoProvider.future);
                            name =
                                (await repo.project(_projectId!))?.name ??
                                    name;
                          }
                          final csv = CsvExport.build(
                            headers: const ['Particulars', 'Amount'],
                            rows: [
                              ['Project:', name],
                              ['Period:', formatPeriod(_from, _to)],
                              ['', ''],
                              if (f.wmRevenue > 0)
                                ['Contract Revenue (With-Material)',
                                    f.wmRevenue.toStringAsFixed(2)],
                              if (f.serviceFees > 0)
                                ['Service Fees',
                                    f.serviceFees.toStringAsFixed(2)],
                              ['Total Income', totalIncome.toStringAsFixed(2)],
                              ['', ''],
                              ['Material Costs',
                                  (-f.matCosts).toStringAsFixed(2)],
                              for (final e
                                  in _sortedByValueDesc(d.materialByType))
                                ['    ${e.key}',
                                    (-e.value).toStringAsFixed(2)],
                              if (d.materialUntracked > 0)
                                ['    Untracked (no inventory row)',
                                    (-d.materialUntracked).toStringAsFixed(2)],
                              ['Labour Costs',
                                  (-f.labCosts).toStringAsFixed(2)],
                              for (final e
                                  in _sortedByValueDesc(d.labourBySupplier))
                                [
                                  '    ${d.supplierNames[e.key] ?? e.key}',
                                  (-e.value).toStringAsFixed(2)
                                ],
                              if (f.personalDraw > 0)
                                ['Personal Draw',
                                    (-f.personalDraw).toStringAsFixed(2)],
                              ['Total Costs',
                                  (-totalCosts).toStringAsFixed(2)],
                              ['Net Profit / (Loss)',
                                  net.toStringAsFixed(2)],
                              if (f.lrDeposit + f.wmDeposit > 0) ...[
                                ['', ''],
                                ['-- Customer Deposits (owed back) --', ''],
                                if (f.lrDeposit > 0)
                                  ['  Labour-Rate projects',
                                      (-f.lrDeposit).toStringAsFixed(2)],
                                if (f.wmDeposit > 0)
                                  ['  Over-budget (With-Material)',
                                      (-f.wmDeposit).toStringAsFixed(2)],
                                ['  Total deposits owed',
                                    (-(f.lrDeposit + f.wmDeposit))
                                        .toStringAsFixed(2)],
                              ],
                            ],
                          );
                          await CsvExport.share(
                            fileName:
                                'income_statement_${DateTime.now().millisecondsSinceEpoch}',
                            csv: csv,
                            subject: 'Income Statement — $name',
                          );
                        },
                      ),
                    ),
                  ]),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext ctx, String label, double v,
      {bool bold = false, Color? color}) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
      color: color,
      fontSize: 16,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text(fmtSignedMoney(v), style: style),
        ],
      ),
    );
  }

  /// Stable order for the breakdown sub-rows: biggest spend first, then
  /// alphabetical on ties. Yields list entries so the spread operator
  /// can splice them straight into the column children.
  List<MapEntry<String, double>> _sortedByValueDesc(Map<String, double> m) {
    final entries = m.entries.toList()
      ..sort((a, b) {
        final byVal = b.value.compareTo(a.value);
        if (byVal != 0) return byVal;
        return a.key.compareTo(b.key);
      });
    return entries;
  }
}

/// Bundle that pairs the canonical PoC P&L from [IncomeFigures] with the
/// finer-grained breakdowns the Income Statement screen renders as
/// indented sub-rows.
class _DetailedFigures {
  final IncomeFigures figures;
  /// Material Costs split by `material_type`.
  final Map<String, double> materialByType;
  /// Material-Costs spend in the journal that has no matching
  /// `material_inventory` row (legacy data or unusual posts).
  final double materialUntracked;
  /// Labour Costs split by supplier id (worker).
  final Map<String, double> labourBySupplier;
  /// Supplier-id → display-name map covering active + archived.
  final Map<String, String> supplierNames;

  const _DetailedFigures({
    required this.figures,
    required this.materialByType,
    required this.materialUntracked,
    required this.labourBySupplier,
    required this.supplierNames,
  });
}

/// Banner shown above the Income Statement when one or more projects are
/// approaching or already past their budget. Mirrors the cost-budget signal
/// from the BvA report so the user sees the loss warning at the P&L level.
class _AtRiskBanner extends StatelessWidget {
  const _AtRiskBanner({required this.risks});
  final List<ProjectAtRisk> risks;

  @override
  Widget build(BuildContext context) {
    final overCount = risks.where((r) => r.isOverBudget).length;
    final warnCount = risks.length - overCount;
    final headlineColor = overCount > 0
        ? BalanceColors.negative(context)
        : Colors.orange.shade700;

    return Card(
      color: (overCount > 0
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
                    color: headlineColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    overCount > 0
                        ? 'Projects at risk — $overCount over budget'
                            '${warnCount > 0 ? ', $warnCount approaching' : ''}'
                        : '$warnCount project(s) approaching budget',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: headlineColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final r in risks.take(5))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(r.projectName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                    ),
                    Text(
                      r.isOverBudget
                          ? '${r.pctConsumed.toStringAsFixed(0)}% — over by ${fmtMoney(r.costsToDate - r.budget)}'
                          : '${r.pctConsumed.toStringAsFixed(0)}% used',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: r.isOverBudget
                              ? BalanceColors.negative(context)
                              : Colors.orange.shade800),
                    ),
                  ],
                ),
              ),
            if (risks.length > 5)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('+ ${risks.length - 5} more',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
