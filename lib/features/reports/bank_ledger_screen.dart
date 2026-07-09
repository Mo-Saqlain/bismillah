import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/models/bank.dart';
import '../../data/models/journal_entry.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';
import '../common/date_range_bar.dart';
import '../common/ledger_view.dart';
import '../common/trial_balance_card.dart';
import '../../core/export/csv_export.dart';
import '../../core/export/pdf_generator.dart';

/// Lists user-defined banks/wallets so the user can drill into a specific
/// account's ledger.
class BankLedgerPickerScreen extends ConsumerWidget {
  const BankLedgerPickerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banks = ref.watch(banksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Choose Bank / Wallet')),
      body: AsyncView<List<Bank>>(
        value: banks,
        data: (list) {
          if (list.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'No banks or wallets yet. Add one from Manage → Wallets & Banks.'),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final b = list[i];
              return Card(
                child: ListTile(
                  leading:
                      const CircleAvatar(child: Icon(Icons.account_balance)),
                  title: Text(b.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle:
                      b.accountNo == null ? null : Text('Acct ${b.accountNo}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => BankLedgerScreen(bank: b),
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

/// Per-bank ledger: every journal entry that touched this bank/wallet, with a
/// running balance (debits − credits = positive cash). Exports to PDF and CSV.
class BankLedgerScreen extends ConsumerStatefulWidget {
  const BankLedgerScreen({super.key, required this.bank});
  final Bank bank;

  @override
  ConsumerState<BankLedgerScreen> createState() => _BankLedgerScreenState();
}

class _BankLedgerScreenState extends ConsumerState<BankLedgerScreen> {
  DateTime? _from;
  DateTime? _to;

  /// Convert raw journal entries into LedgerRows with a running balance
  /// (debits = inflows for an asset account).
  List<LedgerRow> _toRows(List<JournalEntry> entries) {
    double running = 0;
    return entries.map((r) {
      running += r.debit - r.credit;
      return LedgerRow(
        date: r.createdAt,
        memo: r.description ?? '—',
        debit: r.debit,
        credit: r.credit,
        balance: running,
      );
    }).toList();
  }

  Future<void> _exportPdf(List<JournalEntry> entries) async {
    await PdfGenerator.previewBankLedger(BankLedgerData(
      bankName: widget.bank.name,
      rows: entries,
      generatedAt: DateTime.now(),
      period: formatPeriod(_from, _to),
    ));
  }

  Future<void> _exportCsv(List<JournalEntry> entries) async {
    final rows = _toRows(entries);
    final csv = CsvExport.build(
      headers: const [
        'Date',
        'Particulars',
        'Debit (in)',
        'Credit (out)',
        'Balance'
      ],
      rows: [
        ['Account:', widget.bank.name, '', '', ''],
        if (widget.bank.accountNo != null)
          ['Acct No:', widget.bank.accountNo!, '', '', ''],
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
          'bank_ledger_${widget.bank.name}_${DateTime.now().millisecondsSinceEpoch}',
      csv: csv,
      subject: 'Bank Ledger — ${widget.bank.name}',
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(ledgerVersionProvider);
    final entriesAsync = ref.watch(_bankEntriesProvider(_BankFilterKey(
      bankId: widget.bank.id,
      from: _from,
      to: _to,
    )));

    return Scaffold(
      appBar: AppBar(
        title: Text('Ledger · ${widget.bank.name}'),
        actions: [
          LedgerExportActions(
            enabled: entriesAsync.hasValue &&
                (entriesAsync.value?.isNotEmpty ?? false),
            onExportPdf: () async {
              final e = await ref.read(_bankEntriesProvider(_BankFilterKey(
                bankId: widget.bank.id,
                from: _from,
                to: _to,
              )).future);
              await _exportPdf(e);
            },
            onExportCsv: () async {
              final e = await ref.read(_bankEntriesProvider(_BankFilterKey(
                bankId: widget.bank.id,
                from: _from,
                to: _to,
              )).future);
              await _exportCsv(e);
            },
          ),
        ],
      ),
      body: AsyncView<List<JournalEntry>>(
        value: entriesAsync,
        data: (entries) {
          final rows = _toRows(entries);
          final total = rows.isEmpty ? 0.0 : rows.last.balance;
          final totalDr = entries.fold<double>(0, (a, e) => a + e.debit);
          final totalCr = entries.fold<double>(0, (a, e) => a + e.credit);
          return LedgerView(
            title: widget.bank.name,
            subtitle: '${widget.bank.accountNo == null ? '' : 'Acct ${widget.bank.accountNo} · '}'
                'Period: ${formatPeriod(_from, _to)}',
            rows: rows,
            totalLabel: 'Net Balance',
            totalValue: total,
            signedTotal: true,
            debitHeader: 'Dr (in)',
            creditHeader: 'Cr (out)',
            emptyMessage: 'No transactions for this account in the period.',
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
                TrialBalanceCard(
                  title: 'Trial balance',
                  entryCount: entries.length,
                  rows: [
                    TrialBalanceRow(
                      label: 'Money in (Dr)',
                      value: totalDr,
                    ),
                    TrialBalanceRow(
                      label: 'Money out (Cr)',
                      value: totalCr,
                    ),
                    TrialBalanceRow(
                      label: 'Net balance',
                      value: total,
                      bold: true,
                      // Asset account — positive cash is good (green).
                      colorize: total,
                      helper: 'Dr − Cr (asset-account convention)',
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

class _BankFilterKey {
  final String bankId;
  final DateTime? from;
  final DateTime? to;
  const _BankFilterKey({required this.bankId, this.from, this.to});

  @override
  bool operator ==(Object other) =>
      other is _BankFilterKey &&
      other.bankId == bankId &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(bankId, from, to);
}

final _bankEntriesProvider =
    FutureProvider.family<List<JournalEntry>, _BankFilterKey>((ref, key) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  return repo.entriesForAccount(key.bankId, from: key.from, to: key.to);
});
