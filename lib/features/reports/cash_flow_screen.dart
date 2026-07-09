import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/repositories/ledger_repository.dart';
import '../../providers/providers.dart';
import '../common/date_range_bar.dart';
import '../../core/export/csv_export.dart';

/// Cash Flow Statement — combines an FBR-style indirect summary
/// (Operating / Financing / Net Change / Closing Cash) for the chosen
/// period with the existing monthly per-account breakdown for
/// reference. Date filter applies to both halves.
class CashFlowScreen extends ConsumerStatefulWidget {
  const CashFlowScreen({super.key});

  @override
  ConsumerState<CashFlowScreen> createState() => _CashFlowScreenState();
}

class _CashFlowScreenState extends ConsumerState<CashFlowScreen> {
  DateTime? _from;
  DateTime? _to;

  @override
  Widget build(BuildContext context) {
    ref.watch(ledgerVersionProvider);
    final summaryAsync = ref.watch(_summaryProvider(_PeriodKey(_from, _to)));
    final monthlyAsync = ref.watch(_cashFlowProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cash Flow Statement'),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: const Icon(Icons.file_download, size: 26),
            onPressed: () async {
              final s = await ref
                  .read(_summaryProvider(_PeriodKey(_from, _to)).future);
              final m = await ref.read(_cashFlowProvider.future);
              await _exportCsv(s, m);
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
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
          summaryAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text('Error: $e'),
            data: (s) => _SummaryCard(
              summary: s,
              periodLabel: formatPeriod(_from, _to),
            ),
          ),
          const SizedBox(height: 16),
          Text('Monthly Movement (last 12 months)',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          monthlyAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text('Error: $e'),
            data: (bundle) => _MonthlyTable(bundle: bundle),
          ),
          const SizedBox(height: 8),
          Text(
            'Operating activities cover project income and project costs '
            '(material, labour, supplier settlements). Financing covers '
            'personal/owner draws. Wallet transfers are excluded — they '
            'don\'t change consolidated cash.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> _exportCsv(CashFlowSummary s, _CashFlowBundle bundle) async {
    final monthFmt = DateFormat('yyyy-MM');
    final csv = CsvExport.build(
      headers: const ['Section', 'Particulars', 'Amount'],
      rows: [
        ['Period:', formatPeriod(_from, _to), ''],
        ['', '', ''],
        ['Opening Cash', '', s.openingCash.toStringAsFixed(2)],
        ['', '', ''],
        ['OPERATING ACTIVITIES', '', ''],
        if (s.projectInflow != 0)
          ['', 'Received from projects (in)',
              s.projectInflow.toStringAsFixed(2)],
        if (s.serviceFeeInflow != 0)
          ['', 'Service-fee receipts (in)',
              s.serviceFeeInflow.toStringAsFixed(2)],
        if (s.equityInflow != 0)
          ['', 'Opening bank balances (in)',
              s.equityInflow.toStringAsFixed(2)],
        if (s.materialOutflow != 0)
          ['', 'Cash-bought material (out)',
              (-s.materialOutflow).toStringAsFixed(2)],
        if (s.labourOutflow != 0)
          ['', 'Labour paid in cash (out)',
              (-s.labourOutflow).toStringAsFixed(2)],
        if (s.supplierPayOutflow != 0)
          ['', 'Supplier settlements (out)',
              (-s.supplierPayOutflow).toStringAsFixed(2)],
        ['', 'Net cash from operating', s.netOperating.toStringAsFixed(2)],
        ['', '', ''],
        ['FINANCING ACTIVITIES', '', ''],
        if (s.personalDrawOutflow != 0)
          ['', 'Personal / owner draws (out)',
              (-s.personalDrawOutflow).toStringAsFixed(2)],
        if (s.equityOutflow != 0)
          ['', 'Equity withdrawals (out)',
              (-s.equityOutflow).toStringAsFixed(2)],
        ['', 'Net cash from financing', s.netFinancing.toStringAsFixed(2)],
        ['', '', ''],
        if (s.otherNet != 0) ...[
          ['OTHER', '', s.otherNet.toStringAsFixed(2)],
          ['', '', ''],
        ],
        ['Net change in cash', '', s.netChange.toStringAsFixed(2)],
        ['Closing Cash', '', s.closingCash.toStringAsFixed(2)],
        ['', '', ''],
        ['MONTHLY DETAIL', '', ''],
        [
          'Month',
          ...bundle.accounts.map((a) => a.name),
          'Total',
        ],
        for (final m in bundle.rows.reversed)
          [
            monthFmt.format(m.month),
            ...bundle.accounts
                .map((a) => (m.perAccount[a.id] ?? 0).toStringAsFixed(2)),
            m.total.toStringAsFixed(2),
          ],
      ],
    );
    await CsvExport.share(
      fileName: 'cash_flow_${DateTime.now().millisecondsSinceEpoch}',
      csv: csv,
      subject: 'Cash Flow Statement',
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary, required this.periodLabel});
  final CashFlowSummary summary;
  final String periodLabel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Period: $periodLabel',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            _line(context, 'Opening Cash', summary.openingCash, bold: true),
            const Divider(),
            _section(context, 'Operating Activities'),
            // Inflows, line by line. Skip zero rows so the report stays
            // tight on businesses that don't use every channel.
            if (summary.projectInflow != 0)
              _line(context, '  Received from projects (in)',
                  summary.projectInflow),
            if (summary.serviceFeeInflow != 0)
              _line(context, '  Service-fee receipts (in)',
                  summary.serviceFeeInflow),
            if (summary.equityInflow != 0)
              _line(context, '  Opening bank balances (in)',
                  summary.equityInflow),
            // Outflows.
            if (summary.materialOutflow != 0)
              _line(context, '  Cash-bought material (out)',
                  -summary.materialOutflow),
            if (summary.labourOutflow != 0)
              _line(context, '  Labour paid in cash (out)',
                  -summary.labourOutflow),
            if (summary.supplierPayOutflow != 0)
              _line(context, '  Supplier settlements (out)',
                  -summary.supplierPayOutflow),
            _line(context, '  Net cash from operating', summary.netOperating,
                bold: true),
            const SizedBox(height: 8),
            _section(context, 'Financing Activities'),
            if (summary.personalDrawOutflow != 0)
              _line(context, '  Personal / owner draws (out)',
                  -summary.personalDrawOutflow),
            if (summary.equityOutflow != 0)
              _line(context, '  Equity withdrawals (out)',
                  -summary.equityOutflow),
            _line(context, '  Net cash from financing', summary.netFinancing,
                bold: true),
            if (summary.otherNet != 0) ...[
              const SizedBox(height: 8),
              _section(context, 'Other'),
              _line(context, '  Unclassified net', summary.otherNet),
            ],
            const Divider(),
            _line(context, 'Net Change in Cash', summary.netChange,
                bold: true),
            _line(context, 'Closing Cash', summary.closingCash, bold: true),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(label,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _line(BuildContext context, String label, double v,
      {bool bold = false}) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
      color: v == 0 ? null : BalanceColors.signed(context, v),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label,
              style: bold
                  ? const TextStyle(fontWeight: FontWeight.w700)
                  : null)),
          Text(fmtSignedMoney(v), style: style),
        ],
      ),
    );
  }
}

class _MonthlyTable extends StatelessWidget {
  const _MonthlyTable({required this.bundle});
  final _CashFlowBundle bundle;

  static String _short(String name) {
    if (name.length <= 10) return name;
    final parts = name.split(' ');
    return parts.length > 1 ? parts.last : name.substring(0, 10);
  }

  @override
  Widget build(BuildContext context) {
    if (bundle.rows.every((r) => r.total == 0)) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('No cash movement in the last 12 months.')),
      );
    }
    final monthFmt = DateFormat('MMM yy');
    // Newest month on top so the user lands on current activity without
    // scrolling — the repo returns oldest → newest, we just reverse here.
    final ordered = bundle.rows.reversed.toList();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: [
            const DataColumn(label: Text('Month')),
            ...bundle.accounts
                .map((a) => DataColumn(label: Text(_short(a.name)))),
            const DataColumn(label: Text('Total Δ'), numeric: true),
          ],
          rows: [
            for (final m in ordered)
              DataRow(cells: [
                DataCell(Text(monthFmt.format(m.month.toLocal()))),
                ...bundle.accounts.map((a) {
                  final v = m.perAccount[a.id] ?? 0;
                  return DataCell(Text(
                    v == 0 ? '—' : fmtSignedMoney(v),
                    style: TextStyle(
                        color: v == 0
                            ? null
                            : BalanceColors.signed(context, v)),
                  ));
                }),
                DataCell(Text(fmtSignedMoney(m.total),
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: BalanceColors.signed(context, m.total)))),
              ]),
          ],
        ),
      ),
    );
  }
}

class _PeriodKey {
  final DateTime? from;
  final DateTime? to;
  const _PeriodKey(this.from, this.to);

  @override
  bool operator ==(Object other) =>
      other is _PeriodKey && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

final _summaryProvider =
    FutureProvider.family<CashFlowSummary, _PeriodKey>((ref, key) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  return repo.cashFlowSummary(from: key.from, to: key.to);
});

class _CashFlowBundle {
  final List<MonthlyCashFlow> rows;
  final List<Account> accounts;
  const _CashFlowBundle(this.rows, this.accounts);
}

final _cashFlowProvider = FutureProvider<_CashFlowBundle>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  final accounts = await ref.watch(cashLikeAccountsProvider.future);
  final rows = await repo.monthlyCashFlow();
  return _CashFlowBundle(rows, accounts);
});
