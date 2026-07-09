import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/models/party.dart';
import '../../data/repositories/entity_repository.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';

/// Suppliers list. Customers were removed entirely; the client is now just a
/// free-text field on the project.
///
/// Tap on a supplier opens an action sheet (Edit / View info / Archive).
/// Ledgers live in the Reports tab — they intentionally do **not** open from
/// the supplier list.
class SuppliersScreen extends ConsumerStatefulWidget {
  const SuppliersScreen({super.key});

  @override
  ConsumerState<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends ConsumerState<SuppliersScreen> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final list = _showArchived
        ? ref.watch(archivedSuppliersProvider)
        : ref.watch(suppliersProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(_showArchived ? 'Archived Suppliers' : 'Suppliers'),
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
              onPressed: () => _showSupplierForm(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('New Supplier'),
            ),
      body: AsyncView<List<Party>>(
        value: list,
        data: (suppliers) {
          if (suppliers.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.local_shipping,
                        size: 56, color: Colors.grey),
                    const SizedBox(height: 12),
                    Text(
                        _showArchived
                            ? 'No archived suppliers'
                            : 'No suppliers yet',
                        style: Theme.of(context).textTheme.titleMedium),
                    if (!_showArchived) ...[
                      const SizedBox(height: 4),
                      const Text('Tap "New Supplier" to add one.',
                          textAlign: TextAlign.center),
                    ],
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: suppliers.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final p = suppliers[i];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: p.archived
                        ? Colors.brown.shade100
                        : null,
                    child: Icon(
                      p.archived
                          ? Icons.archive
                          : Icons.local_shipping,
                      color: p.archived ? Colors.brown.shade800 : null,
                    ),
                  ),
                  title: Text(p.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        decoration:
                            p.archived ? TextDecoration.lineThrough : null,
                      )),
                  subtitle: _subtitle(p),
                  trailing: Text(fmtDate(p.createdAt),
                      style: Theme.of(context).textTheme.bodySmall),
                  onTap: () => _showSupplierActions(context, ref, p),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget? _subtitle(Party p) {
    final lines = <String>[];
    if (p.phone != null) lines.add(p.phone!);
    if (p.category != null) lines.add(p.category!.label);
    if (p.taxStatus != null) lines.add('Tax: ${p.taxStatus}');
    if (p.archived) lines.add('ARCHIVED');
    if (lines.isEmpty) return null;
    return Text(lines.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis);
  }

  void _showSupplierActions(BuildContext context, WidgetRef ref, Party p) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Wrap(
          children: [
            if (!p.archived)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _showSupplierForm(context, ref, existing: p);
                },
              ),
            if (!p.archived)
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const Text('Archive'),
                subtitle: const Text(
                    'Allowed only when the supplier ledger nets to zero — no money owed in either direction'),
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final repo = await ref.read(entityRepoProvider.future);
                  try {
                    await repo.archiveSupplier(p.id);
                    bumpLedger(ref);
                    if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                  } on SupplierNotSettledException catch (e) {
                    if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                    final amt = e.outstandingBalance;
                    final direction = amt > 0
                        ? 'You still owe them ${fmtMoney(amt)}'
                        : 'They still owe you ${fmtMoney(-amt)}';
                    messenger.showSnackBar(SnackBar(
                      content: Text(
                          'Cannot archive ${p.name} — $direction. Settle the supplier ledger first.'),
                      duration: const Duration(seconds: 6),
                    ));
                  }
                },
              ),
            if (p.archived)
              ListTile(
                leading: const Icon(Icons.unarchive_outlined),
                title: const Text('Unarchive'),
                onTap: () async {
                  final repo = await ref.read(entityRepoProvider.future);
                  await repo.unarchiveSupplier(p.id);
                  bumpLedger(ref);
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showSupplierForm(BuildContext context, WidgetRef ref,
      {Party? existing}) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final phoneCtrl = TextEditingController(text: existing?.phone ?? '');
    final taxCtrl = TextEditingController(text: existing?.taxStatus ?? '');
    final bankCtrl =
        TextEditingController(text: existing?.bankDetails ?? '');
    SupplierCategory? category = existing?.category;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
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
                Text(existing == null ? 'New Supplier' : 'Edit Supplier',
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 16),
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name *'),
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Phone (optional)'),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<SupplierCategory>(
                  initialValue: category,
                  decoration:
                      const InputDecoration(labelText: 'Category (optional)'),
                  items: SupplierCategory.values
                      .map((c) =>
                          DropdownMenuItem(value: c, child: Text(c.label)))
                      .toList(),
                  onChanged: (v) => setSheetState(() => category = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: taxCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Tax status (optional)'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bankCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Bank details (optional)'),
                  maxLines: 2,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    final repo = await ref.read(entityRepoProvider.future);
                    if (existing == null) {
                      await repo.createSupplier(
                        name: name,
                        phone: phoneCtrl.text,
                        category: category,
                        taxStatus: taxCtrl.text,
                        bankDetails: bankCtrl.text,
                      );
                    } else {
                      await repo.updateSupplierFields(
                        existing.id,
                        name: name,
                        phone: phoneCtrl.text,
                        category: category,
                        taxStatus: taxCtrl.text,
                        bankDetails: bankCtrl.text,
                      );
                    }
                    bumpLedger(ref);
                    if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                  },
                  child:
                      Text(existing == null ? 'Create' : 'Save'),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
