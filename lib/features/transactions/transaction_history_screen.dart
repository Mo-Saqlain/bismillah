import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/models/journal_entry.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';
import '../common/date_range_bar.dart';

class TransactionHistoryScreen extends ConsumerStatefulWidget {
  const TransactionHistoryScreen({super.key});

  @override
  ConsumerState<TransactionHistoryScreen> createState() =>
      _TransactionHistoryScreenState();
}

class _TransactionHistoryScreenState
    extends ConsumerState<TransactionHistoryScreen> {
  bool _showDeleted = false;
  DateTime? _from;
  DateTime? _to;

  bool _inWindow(JournalEntry r) {
    final created = r.createdAt.toLocal();
    if (_from != null) {
      final start = DateTime(_from!.year, _from!.month, _from!.day);
      if (created.isBefore(start)) return false;
    }
    if (_to != null) {
      final endExclusive =
          DateTime(_to!.year, _to!.month, _to!.day).add(const Duration(days: 1));
      if (!created.isBefore(endExclusive)) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _showDeleted
        ? ref.watch(allEntriesIncludingDeletedProvider)
        : ref.watch(allEntriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('All Transactions'),
        actions: [
          Row(
            children: [
              const Text('Show deleted', style: TextStyle(fontSize: 13)),
              Switch(
                value: _showDeleted,
                onChanged: (v) => setState(() => _showDeleted = v),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: DateRangeBar(
              from: _from,
              to: _to,
              onChanged: (f, t) => setState(() {
                _from = f;
                _to = t;
              }),
            ),
          ),
          Expanded(
            child: AsyncView<List<JournalEntry>>(
              value: entries,
              data: (rows) {
                final filtered = rows.where(_inWindow).toList();
                if (filtered.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        rows.isEmpty
                            ? 'No transactions yet.'
                            : 'No transactions in ${formatPeriod(_from, _to)}.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                // Group both legs by transaction id.
                final pairs = <String, List<JournalEntry>>{};
                for (final r in filtered) {
                  (pairs[r.transactionId] ??= []).add(r);
                }
                final txnIds = pairs.keys.toList();

                // Build flat item list with date headers.
                // String items = date headers; List<JournalEntry> = txn pairs.
                final items = <Object>[];
                String? lastDate;
                for (final txnId in txnIds) {
                  final pair = pairs[txnId]!;
                  if (pair.isEmpty) continue;
                  final localDate = pair.first.createdAt.toLocal();
                  final dateStr = fmtDate(localDate);
                  if (dateStr != lastDate) {
                    items.add(dateStr);
                    lastDate = dateStr;
                  }
                  items.add(pair);
                }

                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final item = items[i];

                    if (item is String) {
                      return Padding(
                        padding: EdgeInsets.fromLTRB(4, i == 0 ? 4 : 16, 4, 8),
                        child: Text(
                          item,
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                        ),
                      );
                    }

                    final pair = item as List<JournalEntry>;
                    if (pair.length != 2) return const SizedBox.shrink();
                    final dr = pair.firstWhere((e) => e.debit > 0);
                    final cr = pair.firstWhere((e) => e.credit > 0);
                    final isDeleted = dr.deleted;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Card(
                        color: isDeleted
                            ? Theme.of(context)
                                .colorScheme
                                .errorContainer
                                .withValues(alpha: 0.18)
                            : null,
                        child: InkWell(
                          onTap: () => _showActions(
                              context, ref, dr.transactionId, isDeleted),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      fmtMoney(dr.debit),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color: isDeleted
                                                  ? BalanceColors.negative(
                                                      context)
                                                  : null,
                                              decoration: isDeleted
                                                  ? TextDecoration.lineThrough
                                                  : null),
                                    ),
                                    Row(
                                      children: [
                                        if (isDeleted)
                                          const Padding(
                                            padding:
                                                EdgeInsets.only(right: 6),
                                            child: Text('DELETED',
                                                style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight:
                                                        FontWeight.w800)),
                                          ),
                                        if (dr.synced == 0 && !isDeleted)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                right: 6),
                                            child: Icon(Icons.sync,
                                                size: 14,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .secondary),
                                          ),
                                        Text(fmtDateTime(dr.createdAt),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall),
                                        const SizedBox(width: 4),
                                        Icon(Icons.more_vert,
                                            size: 16,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text('Dr  ${Accounts.byId(dr.accountId).name}',
                                    style: TextStyle(
                                      decoration: isDeleted
                                          ? TextDecoration.lineThrough
                                          : null,
                                    )),
                                Text(
                                    '     Cr  ${Accounts.byId(cr.accountId).name}',
                                    style: TextStyle(
                                      decoration: isDeleted
                                          ? TextDecoration.lineThrough
                                          : null,
                                    )),
                                if (dr.description != null &&
                                    dr.description!.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(dr.description!,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showActions(BuildContext context, WidgetRef ref, String txnId,
      bool isDeleted) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Wrap(
          children: [
            if (!isDeleted)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Delete (permanent)'),
                subtitle: const Text(
                    'Removes both ledger rows. Original payload kept in change_log for audit.'),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(sheetCtx);
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Delete this transaction?'),
                      content: const Text(
                          'Both rows of this transaction will be removed from the ledger. '
                          'A copy is preserved in the audit log.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel')),
                        FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: Colors.red),
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Delete')),
                      ],
                    ),
                  );
                  if (confirm != true) return;
                  try {
                    final ledger = await ref.read(ledgerRepoProvider.future);
                    await ledger.hardDeleteTransaction(txnId);
                    bumpLedger(ref);
                    messenger.showSnackBar(
                        const SnackBar(content: Text('Transaction deleted')));
                  } catch (e) {
                    messenger.showSnackBar(
                        SnackBar(content: Text('Delete failed: $e')));
                  }
                },
              ),
            if (!isDeleted)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Soft delete (keeps audit row visible)'),
                subtitle: const Text(
                    'Marks the transaction as deleted but keeps it visible with strikethrough when "Show deleted" is on'),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                  try {
                    final ledger = await ref.read(ledgerRepoProvider.future);
                    await ledger.softDeleteTransaction(txnId);
                    bumpLedger(ref);
                  } catch (e) {
                    messenger.showSnackBar(
                        SnackBar(content: Text('Delete failed: $e')));
                  }
                },
              ),
            if (isDeleted)
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('Restore'),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                  try {
                    final ledger = await ref.read(ledgerRepoProvider.future);
                    await ledger.restoreTransaction(txnId);
                    bumpLedger(ref);
                  } catch (e) {
                    messenger.showSnackBar(
                        SnackBar(content: Text('Restore failed: $e')));
                  }
                },
              ),
            if (!isDeleted)
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('Post Reversing Entry'),
                subtitle: const Text(
                    'Adds an offsetting transaction (recommended for accounting integrity)'),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                  try {
                    final ledger = await ref.read(ledgerRepoProvider.future);
                    await ledger.postReversal(txnId);
                    bumpLedger(ref);
                  } catch (e) {
                    messenger.showSnackBar(
                        SnackBar(content: Text('Failed: $e')));
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}
