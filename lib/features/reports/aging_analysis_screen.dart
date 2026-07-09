import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/models/party.dart';
import '../../data/repositories/ledger_repository.dart';
import '../../providers/providers.dart';
import '../../core/export/csv_export.dart';

/// Aging Analysis — outstanding **supplier payables** bucketed 0-30 / 31-60 /
/// 61-90 / 90+. Receivables aging was removed along with the customer entity:
/// project payments are recognized as revenue immediately so there is nothing
/// receivable.
class AgingAnalysisScreen extends ConsumerStatefulWidget {
  const AgingAnalysisScreen({super.key});

  @override
  ConsumerState<AgingAnalysisScreen> createState() =>
      _AgingAnalysisScreenState();
}

class _AgingAnalysisScreenState extends ConsumerState<AgingAnalysisScreen> {
  Future<void> _exportCsv() async {
    final bundle = await ref.read(_payablesAgingProvider.future);
    final names = {for (final p in bundle.parties) p.id: p.name};
    final csv = CsvExport.build(
      headers: ['Supplier', '0-30', '31-60', '61-90', '90+', 'Total'],
      rows: [
        for (final l in bundle.report.lines)
          [
            names[l.partyId] ?? l.partyId,
            l.bucket0_30.toStringAsFixed(2),
            l.bucket31_60.toStringAsFixed(2),
            l.bucket61_90.toStringAsFixed(2),
            l.bucket90Plus.toStringAsFixed(2),
            l.total.toStringAsFixed(2),
          ],
      ],
    );
    await CsvExport.share(
      fileName: 'aging_payables_${DateTime.now().millisecondsSinceEpoch}',
      csv: csv,
      subject: 'Aging — Payables',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Aging — Payables'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download),
            tooltip: 'Export CSV',
            onPressed: _exportCsv,
          ),
        ],
      ),
      body: const _PayablesTab(),
    );
  }
}

class _PayablesTab extends ConsumerWidget {
  const _PayablesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(ledgerVersionProvider);
    final dataAsync = ref.watch(_payablesAgingProvider);

    return dataAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (bundle) {
        final report = bundle.report;
        if (report.lines.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child:
                  Text('No outstanding payables.', textAlign: TextAlign.center),
            ),
          );
        }
        final partyName = {for (final p in bundle.parties) p.id: p.name};

        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _SummaryCard(report: report),
            const SizedBox(height: 8),
            Card(
              clipBehavior: Clip.antiAlias,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Supplier')),
                    DataColumn(label: Text('0-30'), numeric: true),
                    DataColumn(label: Text('31-60'), numeric: true),
                    DataColumn(label: Text('61-90'), numeric: true),
                    DataColumn(label: Text('90+'), numeric: true),
                    DataColumn(label: Text('Total'), numeric: true),
                  ],
                  rows: [
                    for (final line in report.lines)
                      DataRow(cells: [
                        DataCell(Text(partyName[line.partyId] ??
                            line.partyId.substring(0, 6))),
                        DataCell(Text(fmtMoney(line.bucket0_30))),
                        DataCell(Text(fmtMoney(line.bucket31_60))),
                        DataCell(Text(fmtMoney(line.bucket61_90))),
                        DataCell(Text(fmtMoney(line.bucket90Plus))),
                        DataCell(Text(fmtMoney(line.total),
                            style: const TextStyle(
                                fontWeight: FontWeight.w700))),
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
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.report});
  final AgingReport report;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Total Payable Outstanding',
                style: Theme.of(context).textTheme.titleSmall),
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

class _AgingBundle {
  final AgingReport report;
  final List<Party> parties;
  const _AgingBundle(this.report, this.parties);
}

final _payablesAgingProvider =
    FutureProvider<_AgingBundle>((ref) async {
  ref.watch(ledgerVersionProvider);
  final ledger = await ref.watch(ledgerRepoProvider.future);
  final entityRepo = await ref.watch(entityRepoProvider.future);
  final report = await ledger.aging(
    partyAccountId: Accounts.supplierPayables.id,
  );
  final parties = await entityRepo.suppliers();
  return _AgingBundle(report, parties);
});
