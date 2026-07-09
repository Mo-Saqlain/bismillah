import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/models/journal_entry.dart';
import '../../data/models/party.dart';
import '../../data/models/project.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';
import '../common/date_range_bar.dart';
import '../common/ledger_view.dart';
import '../common/trial_balance_card.dart';
import '../../core/export/csv_export.dart';
import '../../core/export/pdf_generator.dart';

class SupplierLedgerScreen extends ConsumerStatefulWidget {
  const SupplierLedgerScreen({super.key, required this.supplierId});
  final String supplierId;

  @override
  ConsumerState<SupplierLedgerScreen> createState() =>
      _SupplierLedgerScreenState();
}

class _SupplierLedgerScreenState extends ConsumerState<SupplierLedgerScreen> {
  String? _projectFilter;
  DateTime? _from;
  DateTime? _to;
  Party? _supplier;
  List<JournalEntry> _rows = const [];
  List<Project> _projects = const [];
  late Future<void> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<void> _load() async {
    final ent = await ref.read(entityRepoProvider.future);
    final ledger = await ref.read(ledgerRepoProvider.future);
    final all = await ledger.entriesForSupplier(
      widget.supplierId,
      projectId: _projectFilter,
      from: _from,
      to: _to,
    );
    _rows =
        all.where((r) => r.accountId == Accounts.supplierPayables.id).toList();
    _supplier = await ent.supplier(widget.supplierId);
    _projects = await ent.projects();
  }

  void _refilter() {
    setState(() {
      _future = _load();
    });
  }

  /// Convention for a supplier-payables ledger: credits increase the
  /// outstanding amount; debits (settlements) bring it down.
  List<LedgerRow> _toRows(List<JournalEntry> entries) {
    double running = 0;
    return entries.map((r) {
      running += r.credit - r.debit;
      return LedgerRow(
        date: r.createdAt,
        memo: r.description ?? '—',
        debit: r.debit,
        credit: r.credit,
        balance: running,
      );
    }).toList();
  }

  /// FBR-style party meta line (NTN/CNIC + category + tax status).
  /// Empty string when nothing useful is on file.
  String _partyMeta(Party s) {
    final parts = <String>[
      if (s.phone != null && s.phone!.isNotEmpty) 'Ph: ${s.phone}',
      if (s.taxStatus != null && s.taxStatus!.isNotEmpty) 'NTN: ${s.taxStatus}',
      if (s.category != null) s.category!.label,
    ];
    return parts.join(' · ');
  }

  Future<void> _exportPdf() async {
    final s = _supplier;
    if (s == null) return;
    await PdfGenerator.previewSupplierLedger(SupplierLedgerData(
      supplierName: s.name,
      rows: _rows,
      generatedAt: DateTime.now(),
      period: formatPeriod(_from, _to),
      partyMeta: _partyMeta(s),
    ));
  }

  Future<void> _exportCsv() async {
    final s = _supplier;
    if (s == null) return;
    final rows = _toRows(_rows);
    final csv = CsvExport.build(
      headers: const [
        'Date',
        'Particulars',
        'Debit',
        'Credit',
        'Balance'
      ],
      rows: [
        ['Supplier:', s.name, '', '', ''],
        if (_partyMeta(s).isNotEmpty) ['Details:', _partyMeta(s), '', '', ''],
        ['Period:', formatPeriod(_from, _to), '', '', ''],
        ['', '', '', '', ''],
        ...rows.map((r) => [
              fmtDate(r.date),
              r.memo,
              r.debit > 0 ? r.debit.toStringAsFixed(2) : '',
              r.credit > 0 ? r.credit.toStringAsFixed(2) : '',
              r.balance.toStringAsFixed(2),
            ]),
      ],
    );
    await CsvExport.share(
      fileName:
          'supplier_ledger_${s.name}_${DateTime.now().millisecondsSinceEpoch}',
      csv: csv,
      subject: 'Material Supplier Ledger — ${s.name}',
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(ledgerVersionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Material Supplier Ledger'),
        actions: [
          LedgerExportActions(
            enabled: _rows.isNotEmpty,
            onExportPdf: _exportPdf,
            onExportCsv: _exportCsv,
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final supplier = _supplier;
          if (supplier == null) {
            return const Center(child: Text('Supplier not found.'));
          }
          final ledgerRows = _toRows(_rows);
          final total =
              _rows.fold<double>(0, (a, r) => a + r.credit - r.debit);
          final totalDr = _rows.fold<double>(0, (a, r) => a + r.debit);
          final totalCr = _rows.fold<double>(0, (a, r) => a + r.credit);

          return LedgerView(
            title: supplier.name,
            subtitle: '${_partyMeta(supplier)}'
                '${_partyMeta(supplier).isNotEmpty ? ' · ' : ''}'
                'Period: ${formatPeriod(_from, _to)}',
            rows: ledgerRows,
            totalLabel: 'Net Outstanding',
            totalValue: total,
            // Colourise from the business-owner perspective: positive
            // balance (we owe the supplier — a liability) renders red;
            // negative balance (we overpaid them — an asset) renders
            // green. `invertColorSign` flips the sign used for the color
            // because the raw arithmetic convention (`credit − debit`)
            // is the opposite of what's good for us.
            signedTotal: true,
            invertColorSign: true,
            emptyMessage: 'No transactions with this supplier in the period.',
            headerBelowTitle: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DateRangeBar(
                  from: _from,
                  to: _to,
                  onChanged: (f, t) {
                    _from = f;
                    _to = t;
                    _refilter();
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _projectFilter,
                  decoration: const InputDecoration(
                    labelText: 'Filter by Project (optional)',
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('All Projects')),
                    ..._projects.map((p) =>
                        DropdownMenuItem(value: p.id, child: Text(p.name))),
                  ],
                  onChanged: (v) {
                    _projectFilter = v;
                    _refilter();
                  },
                ),
                const SizedBox(height: 12),
                TrialBalanceCard(
                  title: 'Trial balance',
                  entryCount: _rows.length,
                  rows: [
                    TrialBalanceRow(
                      label: 'Settlements paid (Dr)',
                      value: totalDr,
                    ),
                    TrialBalanceRow(
                      label: 'Bills incurred (Cr)',
                      value: totalCr,
                    ),
                    TrialBalanceRow(
                      label: total >= 0 ? 'Outstanding payable' : 'Overpaid (asset)',
                      value: total,
                      bold: true,
                      // Invert: positive arithmetic = we owe (bad → red);
                      // negative = we overpaid (good → green).
                      colorize: -total,
                      helper: 'Cr − Dr (supplier-payable convention)',
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Picker for the Material Supplier Ledger — only material-category
/// suppliers (and uncategorised legacy ones) are listed. Labour suppliers
/// are reached via the Labour Supplier Ledger picker instead so the two
/// reports stay disjoint. The "View Closed" toggle in the AppBar swaps
/// the active list for archived suppliers so the user can pull historical
/// ledgers without unarchiving.
class SupplierLedgerPickerScreen extends ConsumerStatefulWidget {
  const SupplierLedgerPickerScreen({super.key});

  @override
  ConsumerState<SupplierLedgerPickerScreen> createState() =>
      _SupplierLedgerPickerScreenState();
}

class _SupplierLedgerPickerScreenState
    extends ConsumerState<SupplierLedgerPickerScreen> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final suppliers = _showArchived
        ? ref.watch(archivedSuppliersProvider)
        : ref.watch(suppliersProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_showArchived
            ? 'Closed Material Suppliers'
            : 'Material Supplier Ledger'),
        actions: [
          IconButton(
            tooltip: _showArchived
                ? 'Show active suppliers'
                : 'View closed suppliers',
            icon: Icon(
                _showArchived ? Icons.unarchive_outlined : Icons.archive_outlined),
            onPressed: () => setState(() => _showArchived = !_showArchived),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AsyncView<List<Party>>(
        value: suppliers,
        data: (list) {
          final materialSuppliers = list
              .where((s) =>
                  s.category == null ||
                  s.category == SupplierCategory.material)
              .toList();
          if (materialSuppliers.isEmpty) {
            return Center(
                child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_showArchived
                  ? 'No closed material suppliers.'
                  : 'No material suppliers yet. Add one from Manage → Suppliers.'),
            ));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: materialSuppliers.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final s = materialSuppliers[i];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                      child: Icon(_showArchived
                          ? Icons.archive
                          : Icons.local_shipping)),
                  title: Text(s.name,
                      style: _showArchived
                          ? const TextStyle(
                              decoration: TextDecoration.lineThrough)
                          : null),
                  subtitle: Text([
                    if (s.category != null) s.category!.label,
                    if (_showArchived) 'ARCHIVED',
                  ].join(' · ')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          SupplierLedgerScreen(supplierId: s.id),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
