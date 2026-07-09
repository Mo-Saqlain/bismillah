import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/models/bank.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';
import '../reports/bank_ledger_screen.dart';

/// Banks & wallets are first-class accounts now: the user can add as many as
/// they need (the previous hardcoded HBL/Meezan/Alfalah are seed rows on
/// upgrade, not constants in code).
///
/// Tap a row to open the action sheet (View info / Edit / Archive / Delete).
/// Ledgers live in the Reports tab — they intentionally do **not** open from
/// this screen.
class BanksScreen extends ConsumerStatefulWidget {
  const BanksScreen({super.key});

  @override
  ConsumerState<BanksScreen> createState() => _BanksScreenState();
}

class _BanksScreenState extends ConsumerState<BanksScreen> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final banks = _showArchived
        ? ref.watch(archivedBanksProvider)
        : ref.watch(banksProvider);

    return Scaffold(
      appBar: AppBar(
        title:
            Text(_showArchived ? 'Archived Banks & Wallets' : 'Banks & Wallets'),
        actions: [
          IconButton(
            tooltip: _showArchived ? 'Show active' : 'Show archived',
            icon: Icon(
                _showArchived ? Icons.unarchive : Icons.archive_outlined),
            onPressed: () =>
                setState(() => _showArchived = !_showArchived),
          ),
        ],
      ),
      floatingActionButton: _showArchived
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _showBankForm(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('New Bank / Wallet'),
            ),
      body: AsyncView<List<Bank>>(
        value: banks,
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  _showArchived
                      ? 'No archived banks or wallets.'
                      : 'No banks or wallets defined.\nTap "New Bank / Wallet" to add one.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
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
                  leading: CircleAvatar(
                    backgroundColor:
                        b.archived ? Colors.brown.shade100 : null,
                    child: Icon(
                      b.archived ? Icons.archive : Icons.account_balance,
                      color: b.archived ? Colors.brown.shade800 : null,
                    ),
                  ),
                  title: Text(b.name,
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          decoration: b.archived
                              ? TextDecoration.lineThrough
                              : null)),
                  subtitle: Text(b.accountNo == null
                      ? 'Created ${fmtDate(b.createdAt)}'
                      : 'Acct ${b.accountNo} · created ${fmtDate(b.createdAt)}'),
                  onTap: () => _showBankActions(context, ref, b),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showBankActions(BuildContext context, WidgetRef ref, Bank b) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.receipt_long),
              title: const Text('View ledger'),
              subtitle: const Text(
                  'Statement of every transaction through this account'),
              onTap: () {
                Navigator.pop(sheetCtx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BankLedgerScreen(bank: b),
                  ),
                );
              },
            ),
            if (!b.archived)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _showBankForm(context, ref, existing: b);
                },
              ),
            if (!b.archived)
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const Text('Archive'),
                subtitle: const Text(
                    'Hidden from active list — ledger history preserved'),
                onTap: () async {
                  final repo = await ref.read(entityRepoProvider.future);
                  await repo.archiveBank(b.id);
                  bumpLedger(ref);
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                },
              ),
            if (b.archived)
              ListTile(
                leading: const Icon(Icons.unarchive_outlined),
                title: const Text('Unarchive'),
                onTap: () async {
                  final repo = await ref.read(entityRepoProvider.future);
                  await repo.unarchiveBank(b.id);
                  bumpLedger(ref);
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text('Delete (permanent)'),
              subtitle: const Text(
                  'Only allowed if the wallet has never been used in a transaction'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _confirmDelete(context, ref, b);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, Bank b) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${b.name}"?'),
        content: const Text(
            'You can only remove a bank/wallet that has never been used in a transaction. Otherwise archive it instead.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final repo = await ref.read(entityRepoProvider.future);
      await repo.deleteBank(b.id);
      bumpLedger(ref);
      messenger.showSnackBar(SnackBar(content: Text('Removed "${b.name}"')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Cannot delete: $e')));
    }
  }


  void _showBankForm(BuildContext context, WidgetRef ref, {Bank? existing}) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final acctCtrl = TextEditingController(text: existing?.accountNo ?? '');
    final openingCtrl = TextEditingController();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
          left: 16,
          right: 16,
          top: 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(existing == null ? 'New Bank / Wallet' : 'Edit Bank / Wallet',
                  style: Theme.of(sheetCtx).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text(
                'A "wallet" can be any account you pay or receive from — '
                'bank, mobile wallet, partner account, etc.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'Name * (e.g. HBL, EasyPaisa, JazzCash)'),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: acctCtrl,
                decoration: const InputDecoration(
                    labelText: 'Account / wallet number (optional)'),
              ),
              if (existing == null) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: openingCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Opening balance (optional)',
                    prefixText: 'Rs ',
                    helperText:
                        'Posts Dr Bank / Cr Owner\'s Equity so the books stay balanced',
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  final repo = await ref.read(entityRepoProvider.future);
                  if (existing == null) {
                    final created = await repo.createBank(
                      name: name,
                      accountNo: acctCtrl.text,
                    );
                    final opening = double.tryParse(openingCtrl.text.trim()) ?? 0;
                    if (opening > 0) {
                      final ledger =
                          await ref.read(ledgerRepoProvider.future);
                      await ledger.postOpeningBalance(
                        bankAccount: Account(
                            created.id, created.name, AccountType.asset),
                        amount: opening,
                      );
                    }
                  } else {
                    await repo.updateBankFields(
                      existing.id,
                      name: name,
                      accountNo: acctCtrl.text,
                    );
                  }
                  bumpLedger(ref);
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                },
                child: Text(existing == null ? 'Create' : 'Save'),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}
