import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/models/party.dart';
import '../../data/models/project.dart';
import '../../data/repositories/ledger_repository.dart';
import '../../providers/providers.dart';
import '../../core/export/csv_export.dart';

/// Aging — Receivables. Two sources of "money owed to us" since the
/// customer entity was removed:
///   * **Projects** — when the contractor has spent more on a project
///     than the customer has paid in. Bucketed by the age of the
///     unmatched cost rows (FIFO).
///   * **Suppliers** — when we've paid a supplier more than we've been
///     billed (an advance sitting on their books). Bucketed by the age
///     of the unmatched payment rows.
///
/// Each appears in its own tab so the user can see who owes them what
/// and how stale it is.
class AgingReceivablesScreen extends ConsumerStatefulWidget {
  const AgingReceivablesScreen({super.key});

  @override
  ConsumerState<AgingReceivablesScreen> createState() =>
      _AgingReceivablesScreenState();
}

class _AgingReceivablesScreenState extends ConsumerState<AgingReceivablesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _exportCsv() async {
    final bundle = await ref.read(_receivablesAgingProvider.future);
    final projectName = {for (final p in bundle.projects) p.id: p.name};
    final supplierName = {for (final s in bundle.suppliers) s.id: s.name};

    final csv = CsvExport.build(
      headers: const ['Section', 'Party', '0-30', '31-60', '61-90', '90+', 'Total'],
      rows: [
        for (final l in bundle.projectsReport.lines)
          [
            'Project',
            projectName[l.partyId] ?? l.partyId,
            l.bucket0_30.toStringAsFixed(2),
            l.bucket31_60.toStringAsFixed(2),
            l.bucket61_90.toStringAsFixed(2),
            l.bucket90Plus.toStringAsFixed(2),
            l.total.toStringAsFixed(2),
          ],
        for (final l in bundle.suppliersReport.lines)
          [
            'Supplier (overpaid)',
            supplierName[l.partyId] ?? l.partyId,
            l.bucket0_30.toStringAsFixed(2),
            l.bucket31_60.toStringAsFixed(2),
            l.bucket61_90.toStringAsFixed(2),
            l.bucket90Plus.toStringAsFixed(2),
            l.total.toStringAsFixed(2),
          ],
      ],
    );
    await CsvExport.share(
      fileName: 'aging_receivables_${DateTime.now().millisecondsSinceEpoch}',
      csv: csv,
      subject: 'Aging — Receivables',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Aging — Receivables'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Projects'),
            Tab(text: 'Supplier Overpaid'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download, size: 26),
            tooltip: 'Export CSV',
            onPressed: _exportCsv,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [_ProjectsTab(), _SuppliersTab()],
      ),
    );
  }
}

class _ProjectsTab extends ConsumerWidget {
  const _ProjectsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(ledgerVersionProvider);
    final dataAsync = ref.watch(_receivablesAgingProvider);
    return dataAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (bundle) {
        final report = bundle.projectsReport;
        final names = {for (final p in bundle.projects) p.id: p.name};
        return _ReportBody(
          report: report,
          partyHeader: 'Project',
          partyName: (id) => names[id] ?? 'Project ${id.substring(0, 6)}',
          totalLabel: 'Total Owed by Customers',
          emptyMessage: 'Every project is fully funded by its customer.',
        );
      },
    );
  }
}

class _SuppliersTab extends ConsumerWidget {
  const _SuppliersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(ledgerVersionProvider);
    final dataAsync = ref.watch(_receivablesAgingProvider);
    return dataAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (bundle) {
        final report = bundle.suppliersReport;
        final names = {for (final s in bundle.suppliers) s.id: s.name};
        return _ReportBody(
          report: report,
          partyHeader: 'Supplier',
          partyName: (id) => names[id] ?? 'Supplier ${id.substring(0, 6)}',
          totalLabel: 'Total Owed by Suppliers',
          emptyMessage: 'No supplier currently holds an advance.',
        );
      },
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({
    required this.report,
    required this.partyHeader,
    required this.partyName,
    required this.totalLabel,
    required this.emptyMessage,
  });

  final AgingReport report;
  final String partyHeader;
  final String Function(String id) partyName;
  final String totalLabel;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (report.lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(emptyMessage, textAlign: TextAlign.center),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _SummaryCard(report: report, totalLabel: totalLabel),
        const SizedBox(height: 8),
        Card(
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                DataColumn(label: Text(partyHeader)),
                const DataColumn(label: Text('0-30'), numeric: true),
                const DataColumn(label: Text('31-60'), numeric: true),
                const DataColumn(label: Text('61-90'), numeric: true),
                const DataColumn(label: Text('90+'), numeric: true),
                const DataColumn(label: Text('Total'), numeric: true),
              ],
              rows: [
                for (final line in report.lines)
                  DataRow(cells: [
                    DataCell(Text(partyName(line.partyId))),
                    DataCell(Text(fmtMoney(line.bucket0_30))),
                    DataCell(Text(fmtMoney(line.bucket31_60))),
                    DataCell(Text(fmtMoney(line.bucket61_90))),
                    DataCell(Text(fmtMoney(line.bucket90Plus))),
                    DataCell(Text(fmtMoney(line.total),
                        style: const TextStyle(fontWeight: FontWeight.w700))),
                  ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text('As of ${fmtDateTime(report.asOf)}',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.report, required this.totalLabel});
  final AgingReport report;
  final String totalLabel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(totalLabel, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(fmtMoney(report.grandTotal),
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Row(
              children: [
                _Bucket(label: '0-30', value: report.total0_30),
                _Bucket(label: '31-60', value: report.total31_60),
                _Bucket(label: '61-90', value: report.total61_90),
                _Bucket(label: '90+', value: report.total90Plus, danger: true),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Bucket extends StatelessWidget {
  const _Bucket({required this.label, required this.value, this.danger = false});
  final String label;
  final double value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: danger ? colors.errorContainer : colors.secondaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 2),
            Text(fmtMoney(value),
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _ReceivablesBundle {
  final AgingReport projectsReport;
  final AgingReport suppliersReport;
  final List<Project> projects;
  final List<Party> suppliers;
  const _ReceivablesBundle({
    required this.projectsReport,
    required this.suppliersReport,
    required this.projects,
    required this.suppliers,
  });
}

final _receivablesAgingProvider =
    FutureProvider<_ReceivablesBundle>((ref) async {
  ref.watch(ledgerVersionProvider);
  final ledger = await ref.watch(ledgerRepoProvider.future);
  final entityRepo = await ref.watch(entityRepoProvider.future);
  final pReport = await ledger.agingProjectReceivables();
  final sReport = await ledger.agingSupplierOverpayment();
  // Pull archived rows too — a project/supplier may be archived but still
  // appear in receivables history; we want the friendly name for the row.
  final projects = await entityRepo.projects(includeArchived: true);
  final suppliers = await entityRepo.suppliers(includeArchived: true);
  return _ReceivablesBundle(
    projectsReport: pReport,
    suppliersReport: sReport,
    projects: projects,
    suppliers: suppliers,
  );
});
