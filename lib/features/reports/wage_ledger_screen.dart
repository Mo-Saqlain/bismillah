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

/// Picker for the Labour Supplier Ledger — only labour-category suppliers
/// (and uncategorised legacy ones) appear, since this is a per-worker view
/// of what we owe each labourer. The "View Closed" toggle pulls archived
/// workers so the user can review historical wages.
class WageLedgerPickerScreen extends ConsumerStatefulWidget {
  const WageLedgerPickerScreen({super.key});

  @override
  ConsumerState<WageLedgerPickerScreen> createState() =>
      _WageLedgerPickerScreenState();
}

class _WageLedgerPickerScreenState
    extends ConsumerState<WageLedgerPickerScreen> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final suppliers = _showArchived
        ? ref.watch(archivedSuppliersProvider)
        : ref.watch(suppliersProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_showArchived
            ? 'Closed Labour Suppliers'
            : 'Labour Supplier Ledger'),
        actions: [
          IconButton(
            tooltip: _showArchived
                ? 'Show active workers'
                : 'View closed workers',
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
          final workers = list
              .where((s) =>
                  s.category == null || s.category == SupplierCategory.labor)
              .toList();
          if (workers.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_showArchived
                    ? 'No closed labour suppliers.'
                    : 'No labour-category suppliers yet. Add one from Manage → Suppliers.'),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: workers.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final w = workers[i];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                      child: Icon(_showArchived
                          ? Icons.archive
                          : Icons.engineering)),
                  title: Text(w.name,
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          decoration: _showArchived
                              ? TextDecoration.lineThrough
                              : null)),
                  subtitle: Text([
                    if (w.phone != null) 'Ph: ${w.phone}',
                    if (_showArchived) 'ARCHIVED',
                  ].join(' · ')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => WageLedgerScreen(worker: w),
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

/// Per-worker wage ledger.
///
/// Three transaction kinds end up here:
///   * **Labour on Credit** (Dr Labour Costs / Cr Supplier Payables) — wages
///     incurred but not paid. Adds to the Wages column AND increases the
///     running balance owed.
///   * **Labour Payment**   (Dr Labour Costs / Cr Cash) — wages paid in cash
///     immediately. Adds to BOTH the Wages and Paid columns; the running
///     balance is unchanged (work was charged AND settled in one step).
///   * **Supplier Pay**     (Dr Supplier Payables / Cr Cash) for this
///     worker — settles previously-credited wages. Only the Paid column;
///     reduces the running balance.
///
/// Running balance = Wages − Paid = what we currently owe this worker.
/// Positive = owed; zero = settled. The earlier implementation summed
/// every Labour Costs debit as cumulative wages, which made a Labour
/// Payment look like it added to the balance instead of clearing
/// equivalent wages.
class WageLedgerScreen extends ConsumerStatefulWidget {
  const WageLedgerScreen({super.key, required this.worker});
  final Party worker;

  @override
  ConsumerState<WageLedgerScreen> createState() => _WageLedgerScreenState();
}

class _WageLedgerScreenState extends ConsumerState<WageLedgerScreen> {
  DateTime? _from;
  DateTime? _to;
  /// Optional project filter — null means "every project this worker
  /// touched". Mirrors the supplier ledger's project drop-down.
  String? _projectId;

  /// Walks the journal in chronological order and emits one wage-ledger row
  /// per transaction. Classification is by the pair of accounts that the
  /// transaction touches, since each `_post` writes both legs tagged with
  /// the same `supplier_id`.
  List<LedgerRow> _toRows(List<JournalEntry> entries) {
    // Group both legs of each transaction together.
    final byTxn = <String, List<JournalEntry>>{};
    for (final e in entries) {
      (byTxn[e.transactionId] ??= []).add(e);
    }

    // Sort chronologically by the transaction's first row.
    final txns = byTxn.values.toList()
      ..sort((a, b) => a.first.createdAt.compareTo(b.first.createdAt));

    double running = 0;
    final out = <LedgerRow>[];

    for (final pair in txns) {
      if (pair.length != 2) continue; // malformed — skip
      final accountIds = pair.map((r) => r.accountId).toSet();
      // Material costs got mistakenly tagged with this supplier? Skip — the
      // wage ledger only cares about labour activity.
      if (accountIds.contains(Accounts.materialCosts.id)) continue;

      final hasLabour = accountIds.contains(Accounts.labourCosts.id);
      final hasPayable =
          accountIds.contains(Accounts.supplierPayables.id);

      final firstCreated = pair.first.createdAt;

      if (hasLabour && hasPayable) {
        // Labour on credit — wages incurred, balance goes up.
        final labour = pair.firstWhere(
            (r) => r.accountId == Accounts.labourCosts.id);
        final amount = labour.debit;
        running += amount;
        out.add(LedgerRow(
          date: firstCreated,
          memo: labour.description ?? 'Labour on credit',
          debit: amount, // wages
          credit: 0, // not paid
          balance: running,
        ));
      } else if (hasLabour) {
        // Labour payment — wages charged AND paid in cash, no net effect
        // on the balance. We still surface both numbers so the user can see
        // the activity in this ledger.
        final labour = pair.firstWhere(
            (r) => r.accountId == Accounts.labourCosts.id);
        final amount = labour.debit;
        out.add(LedgerRow(
          date: firstCreated,
          memo: labour.description ?? 'Labour paid in cash',
          debit: amount, // wages
          credit: amount, // paid right away
          balance: running, // unchanged
        ));
      } else if (hasPayable) {
        // Supplier Pay against this worker's credited wages.
        final payable = pair.firstWhere(
            (r) => r.accountId == Accounts.supplierPayables.id);
        final amount = payable.debit;
        running -= amount;
        out.add(LedgerRow(
          date: firstCreated,
          memo: payable.description ?? 'Settlement',
          debit: 0,
          credit: amount, // paid
          balance: running,
        ));
      }
    }

    return out;
  }

  Future<void> _exportPdf(List<JournalEntry> entries) async {
    await PdfGenerator.previewWorkerLedger(WorkerLedgerData(
      workerName: widget.worker.name,
      rows: entries,
      generatedAt: DateTime.now(),
      period: formatPeriod(_from, _to),
    ));
  }

  Future<void> _exportCsv(List<JournalEntry> entries) async {
    final rows = _toRows(entries);
    final wagesTotal = rows.fold<double>(0, (a, r) => a + r.debit);
    final paidTotal = rows.fold<double>(0, (a, r) => a + r.credit);
    final balance = rows.isEmpty ? 0.0 : rows.last.balance;
    final csv = CsvExport.build(
      headers: const [
        'Date',
        'Particulars',
        'Wages',
        'Paid',
        'Balance Owed'
      ],
      rows: [
        ['Worker:', widget.worker.name, '', '', ''],
        if (widget.worker.phone != null)
          ['Phone:', widget.worker.phone!, '', '', ''],
        ['Period:', formatPeriod(_from, _to), '', '', ''],
        ['', '', '', '', ''],
        ...rows.map((r) => [
              fmtDate(r.date),
              r.memo,
              r.debit > 0 ? r.debit.toStringAsFixed(2) : '',
              r.credit > 0 ? r.credit.toStringAsFixed(2) : '',
              r.balance.toStringAsFixed(2),
            ]),
        ['', '', '', '', ''],
        [
          'Totals:',
          '',
          wagesTotal.toStringAsFixed(2),
          paidTotal.toStringAsFixed(2),
          balance.toStringAsFixed(2)
        ],
      ],
    );
    await CsvExport.share(
      fileName:
          'wage_ledger_${widget.worker.name}_${DateTime.now().millisecondsSinceEpoch}',
      csv: csv,
      subject: 'Wage Ledger — ${widget.worker.name}',
    );
  }

  _WageFilterKey get _key => _WageFilterKey(
        supplierId: widget.worker.id,
        projectId: _projectId,
        from: _from,
        to: _to,
      );

  @override
  Widget build(BuildContext context) {
    ref.watch(ledgerVersionProvider);
    final entriesAsync = ref.watch(_workerEntriesProvider(_key));
    final projectsAsync = ref.watch(projectsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Wage · ${widget.worker.name}'),
        actions: [
          LedgerExportActions(
            enabled: entriesAsync.hasValue &&
                (entriesAsync.value?.isNotEmpty ?? false),
            onExportPdf: () async {
              final e =
                  await ref.read(_workerEntriesProvider(_key).future);
              await _exportPdf(e);
            },
            onExportCsv: () async {
              final e =
                  await ref.read(_workerEntriesProvider(_key).future);
              await _exportCsv(e);
            },
          ),
        ],
      ),
      body: AsyncView<List<JournalEntry>>(
        value: entriesAsync,
        data: (entries) {
          final rows = _toRows(entries);
          final balance = rows.isEmpty ? 0.0 : rows.last.balance;
          final wagesTotal = rows.fold<double>(0, (a, r) => a + r.debit);
          final paidTotal = rows.fold<double>(0, (a, r) => a + r.credit);
          return LedgerView(
            title: widget.worker.name,
            subtitle: '${widget.worker.phone == null ? '' : 'Ph: ${widget.worker.phone} · '}'
                'Period: ${formatPeriod(_from, _to)}',
            rows: rows,
            totalLabel: 'Balance Owed to Worker',
            totalValue: balance,
            // Sign matters here: positive = we owe the worker (liability,
            // bad for us → red), zero = settled, negative = we over-paid
            // (worker owes us, asset → green). `invertColorSign` flips
            // the colour so a positive owed-to-worker balance shows red.
            signedTotal: true,
            invertColorSign: true,
            debitHeader: 'Wages',
            creditHeader: 'Paid',
            balanceHeader: 'Owed',
            emptyMessage: 'No wage activity for this worker in the period.',
            headerBelowTitle: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                  value: projectsAsync,
                  data: (projects) => DropdownButtonFormField<String?>(
                    initialValue: _projectId,
                    decoration: const InputDecoration(
                      labelText: 'Filter by Project (optional)',
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text('All Projects')),
                      ...projects.map((p) => DropdownMenuItem(
                          value: p.id, child: Text(p.name))),
                    ],
                    onChanged: (v) => setState(() => _projectId = v),
                  ),
                ),
                const SizedBox(height: 12),
                TrialBalanceCard(
                  title: 'Trial balance',
                  entryCount: rows.length,
                  rows: [
                    TrialBalanceRow(
                      label: 'Wages booked',
                      value: wagesTotal,
                    ),
                    TrialBalanceRow(
                      label: 'Paid',
                      value: paidTotal,
                    ),
                    TrialBalanceRow(
                      label: balance >= 0
                          ? 'Owed to worker'
                          : 'Overpaid (worker owes us)',
                      value: balance,
                      bold: true,
                      // Positive owed = liability for us → red.
                      colorize: -balance,
                      helper: 'Wages − Paid',
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

class _WageFilterKey {
  final String supplierId;
  final String? projectId;
  final DateTime? from;
  final DateTime? to;
  const _WageFilterKey({
    required this.supplierId,
    this.projectId,
    this.from,
    this.to,
  });

  @override
  bool operator ==(Object other) =>
      other is _WageFilterKey &&
      other.supplierId == supplierId &&
      other.projectId == projectId &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(supplierId, projectId, from, to);
}

/// Pulls every entry tagged with this worker's supplier_id (both legs of
/// every transaction). When a project is also selected, the repo filters
/// to that project too so the screen can scope wages to a single site.
/// The screen filters/classifies in memory so we can distinguish Labour
/// Credit / Labour Payment / Supplier Pay by the pair of accounts each
/// transaction touched.
final _workerEntriesProvider =
    FutureProvider.family<List<JournalEntry>, _WageFilterKey>((ref, key) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  return repo.entriesForSupplier(
    key.supplierId,
    projectId: key.projectId,
    from: key.from,
    to: key.to,
  );
});
