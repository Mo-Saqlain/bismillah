import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';
import '../../core/export/csv_export.dart';
import '../../core/export/pdf_generator.dart';

/// Balance Sheet — a complete accrual position statement.
///
/// Beyond the cash/bank ledger balances it surfaces the off-ledger
/// positions the business actually carries: money owed by under-funded
/// projects and advances sitting with suppliers (assets), and customer
/// advances (unearned receipts) plus the provision for over-budget
/// projects (liabilities).
///
/// There is no contributed owner capital in this business, so the bottom
/// line is **Net Worth** (= Assets − Liabilities) — profit retained from
/// work done. Cumulative recognized profit from the P&L is shown as a
/// memo cross-check rather than a forced "equity" plug.
class BalanceSheetScreen extends ConsumerWidget {
  const BalanceSheetScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(accountSummaryProvider);
    final banks = ref.watch(banksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Balance Sheet')),
      body: AsyncView(
        value: summary,
        data: (s) {
          final assets = s.cash +
              s.totalBanks +
              s.counterReceivables +
              s.projectReceivables +
              s.supplierOverpayments;
          final liabilities = s.payables +
              s.counterPayables +
              s.customerDeposits +
              s.lossProvision;
          final netWorth = assets - liabilities;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ── Assets ───────────────────────────────────────────────
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Assets',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 6),
                      _row('Cash', s.cash),
                      AsyncView(
                        value: banks,
                        data: (list) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final b in list)
                              _row(b.name, s.bankBalances[b.id] ?? 0),
                          ],
                        ),
                      ),
                      if (s.counterReceivables > 0)
                        _row('Counter Receivables', s.counterReceivables),
                      if (s.projectReceivables > 0)
                        _row('Project Receivables (under-funded)',
                            s.projectReceivables),
                      if (s.supplierOverpayments > 0)
                        _row('Supplier Advances', s.supplierOverpayments),
                      const Divider(),
                      _row('Total Assets', assets, bold: true),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // ── Liabilities ──────────────────────────────────────────
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Liabilities',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 6),
                      _row('Supplier Payables', s.payables),
                      if (s.counterPayables > 0)
                        _row('Counter Payables', s.counterPayables),
                      if (s.customerDeposits > 0)
                        _row('Customer Advances (unearned)',
                            s.customerDeposits),
                      if (s.lossProvision > 0)
                        _row('Provision for Project Losses', s.lossProvision),
                      const Divider(),
                      _row('Total Liabilities', liabilities, bold: true),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // ── Net Worth + cross-check ──────────────────────────────
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _row('Net Worth (retained in business)', netWorth,
                          bold: true),
                      const Divider(),
                      _row('Accumulated profit to date (P&L)', s.netProfit),
                      const SizedBox(height: 8),
                      Text(
                        'This business holds no contributed owner capital — '
                        'net worth is profit retained from completed and '
                        'in-progress work. It can exceed accumulated profit '
                        'while projects are in progress: the balance sheet '
                        'shows the full receivable from an under-funded job, '
                        'while the P&L defers recognition until cash and '
                        'costs match (cost-recovery PoC). They converge as '
                        'projects close. Counter receivables/payables and '
                        'opening cash entered directly can widen the gap '
                        'further.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.picture_as_pdf),
                      label: const Text('PDF'),
                      onPressed: () async {
                        final list = await ref.read(banksProvider.future);
                        await PdfGenerator.previewBalanceSheet(
                          BalanceSheetData(
                            cash: s.cash,
                            bankRows: [
                              for (final b in list)
                                (b.name, s.bankBalances[b.id] ?? 0),
                            ],
                            counterReceivables: s.counterReceivables,
                            projectReceivables: s.projectReceivables,
                            supplierAdvances: s.supplierOverpayments,
                            payables: s.payables,
                            counterPayables: s.counterPayables,
                            customerDeposits: s.customerDeposits,
                            lossProvision: s.lossProvision,
                            accumulatedProfit: s.netProfit,
                            generatedAt: DateTime.now(),
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
                        final list = await ref.read(banksProvider.future);
                        final csv = CsvExport.build(
                          headers: ['Line', 'Amount'],
                          rows: [
                            ['Cash', s.cash.toStringAsFixed(2)],
                            for (final b in list)
                              [
                                b.name,
                                (s.bankBalances[b.id] ?? 0).toStringAsFixed(2)
                              ],
                            if (s.counterReceivables > 0)
                              [
                                'Counter Receivables',
                                s.counterReceivables.toStringAsFixed(2)
                              ],
                            if (s.projectReceivables > 0)
                              [
                                'Project Receivables (under-funded)',
                                s.projectReceivables.toStringAsFixed(2)
                              ],
                            if (s.supplierOverpayments > 0)
                              [
                                'Supplier Advances',
                                s.supplierOverpayments.toStringAsFixed(2)
                              ],
                            ['Total Assets', assets.toStringAsFixed(2)],
                            [
                              'Supplier Payables',
                              s.payables.toStringAsFixed(2)
                            ],
                            if (s.counterPayables > 0)
                              [
                                'Counter Payables',
                                s.counterPayables.toStringAsFixed(2)
                              ],
                            if (s.customerDeposits > 0)
                              [
                                'Customer Advances (unearned)',
                                s.customerDeposits.toStringAsFixed(2)
                              ],
                            if (s.lossProvision > 0)
                              [
                                'Provision for Project Losses',
                                s.lossProvision.toStringAsFixed(2)
                              ],
                            ['Total Liabilities', liabilities.toStringAsFixed(2)],
                            [
                              'Net Worth (retained in business)',
                              netWorth.toStringAsFixed(2)
                            ],
                            [
                              'Accumulated profit to date (P&L)',
                              s.netProfit.toStringAsFixed(2)
                            ],
                          ],
                        );
                        await CsvExport.share(
                          fileName:
                              'balance_sheet_${DateTime.now().millisecondsSinceEpoch}',
                          csv: csv,
                          subject: 'Balance Sheet',
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(String label, double v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontWeight:
                          bold ? FontWeight.w700 : FontWeight.normal)),
            ),
            Text(fmtMoney(v),
                style: TextStyle(
                    fontWeight: bold ? FontWeight.w700 : FontWeight.normal)),
          ],
        ),
      );
}
