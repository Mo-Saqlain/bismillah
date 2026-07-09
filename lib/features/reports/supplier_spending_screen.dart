import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/repositories/ledger_repository.dart';
import '../../providers/providers.dart';
import '../../core/export/csv_export.dart';

/// Horizontal-bar breakdown of every supplier ranked by total spend
/// (material costs + labour costs combined). The bar length is proportional
/// to the top spender so differences are immediately readable.
///
/// A date filter lets the owner see "last 30 days" vs "all time" without
/// needing a full date picker — the three most useful windows for a
/// construction business are all-time, quarterly, and monthly.
class SupplierSpendingScreen extends ConsumerStatefulWidget {
  const SupplierSpendingScreen({super.key});

  @override
  ConsumerState<SupplierSpendingScreen> createState() =>
      _SupplierSpendingScreenState();
}

enum _Window { allTime, last90, last30 }

class _SupplierSpendingScreenState
    extends ConsumerState<SupplierSpendingScreen> {
  _Window _window = _Window.allTime;

  int? get _daysBack => switch (_window) {
        _Window.allTime => null,
        _Window.last90 => 90,
        _Window.last30 => 30,
      };

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(_supplierSpendProvider(_daysBack));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Supplier-wise Spending'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download),
            tooltip: 'Export CSV',
            onPressed: () async {
              final data = await ref.read(_supplierSpendProvider(_daysBack).future);
              final entityRepo = await ref.read(entityRepoProvider.future);
              final suppliers = await entityRepo.suppliers();
              final nameMap = {for (final s in suppliers) s.id: s.name};
              await _exportCsv(data, nameMap);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Period toggle
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: SegmentedButton<_Window>(
              segments: const [
                ButtonSegment(value: _Window.allTime, label: Text('All Time')),
                ButtonSegment(value: _Window.last90, label: Text('90 Days')),
                ButtonSegment(value: _Window.last30, label: Text('30 Days')),
              ],
              selected: {_window},
              onSelectionChanged: (s) => setState(() => _window = s.first),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: dataAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (rows) {
                if (rows.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No supplier spending recorded for this period.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return _SpendingList(rows: rows, daysBack: _daysBack);
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportCsv(
      List<SupplierSpend> data, Map<String, String> nameMap) async {
    final csv = CsvExport.build(
      headers: ['Supplier', 'Total Spend'],
      rows: data
          .map((r) => [
                nameMap[r.supplierId] ?? r.supplierId,
                r.total.toStringAsFixed(2),
              ])
          .toList(),
    );
    await CsvExport.share(
      fileName: 'supplier_spending_${DateTime.now().millisecondsSinceEpoch}',
      csv: csv,
      subject: 'Supplier-wise Spending',
    );
  }
}

class _SpendingList extends ConsumerWidget {
  const _SpendingList({required this.rows, required this.daysBack});
  final List<SupplierSpend> rows;
  final int? daysBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suppliersAsync = ref.watch(suppliersProvider);
    final allSuppliersAsync = ref.watch(archivedSuppliersProvider);

    return suppliersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (active) {
        return allSuppliersAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (archived) {
            final nameMap = {
              for (final s in [...active, ...archived]) s.id: s.name,
            };
            final maxTotal = rows.first.total;
            final grandTotal =
                rows.fold<double>(0, (s, r) => s + r.total);

            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              itemCount: rows.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${rows.length} suppliers',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall),
                                const SizedBox(height: 2),
                                Text(fmtMoney(grandTotal),
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(
                                            fontWeight: FontWeight.w700)),
                                Text(
                                    daysBack == null
                                        ? 'Total spend — all time'
                                        : 'Total spend — last $daysBack days',
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                              ],
                            ),
                            Icon(Icons.people_outline,
                                size: 40,
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.4)),
                          ],
                        ),
                      ),
                    ),
                  );
                }

                final row = rows[i - 1];
                final name = nameMap[row.supplierId] ??
                    row.supplierId.substring(0, 8);
                final barFraction =
                    maxTotal > 0 ? (row.total / maxTotal) : 0.0;
                final pct = grandTotal > 0
                    ? (row.total / grandTotal * 100).toStringAsFixed(1)
                    : '0';

                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(fmtMoney(row.total),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 13)),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: 38,
                            child: Text('$pct%',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: barFraction,
                          minHeight: 10,
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          color: _barColor(context, i - 1),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  static const _colors = [
    Colors.indigo,
    Colors.teal,
    Colors.orange,
    Colors.purple,
    Colors.cyan,
    Colors.deepOrange,
    Colors.green,
    Colors.pink,
  ];

  Color _barColor(BuildContext context, int index) =>
      _colors[index % _colors.length];
}

final _supplierSpendProvider =
    FutureProvider.family<List<SupplierSpend>, int?>((ref, daysBack) async {
  ref.watch(ledgerVersionProvider);
  final ledger = await ref.watch(ledgerRepoProvider.future);
  return ledger.supplierSpending(daysBack: daysBack);
});
