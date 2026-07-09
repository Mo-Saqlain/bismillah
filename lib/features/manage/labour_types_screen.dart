import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/models/labour_type_def.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';

class LabourTypesScreen extends ConsumerWidget {
  const LabourTypesScreen({super.key});

  Future<void> _addOrEdit(
      BuildContext context, WidgetRef ref, LabourTypeDef? existing) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<LabourTypeDef>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LabourTypeForm(initial: existing),
    );
    if (result == null) return;
    final repo = await ref.read(entityRepoProvider.future);
    try {
      if (existing == null) {
        await repo.addLabourType(
          result.name,
          description: result.description,
          defaultDailyRate: result.defaultDailyRate,
        );
      } else {
        await repo.updateLabourType(
          existing.id,
          name: result.name,
          description: result.description,
          defaultDailyRate: result.defaultDailyRate,
        );
      }
      bumpLedger(ref);
      messenger.showSnackBar(SnackBar(
          content: Text(
              existing == null ? 'Added "${result.name}".' : 'Saved.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, LabourTypeDef row) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${row.name}"?'),
        content: const Text(
            'This removes the option from the Labour dropdown. '
            'Past transactions keep the label recorded in their description.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    final repo = await ref.read(entityRepoProvider.future);
    await repo.deleteLabourType(row.id);
    bumpLedger(ref);
    messenger.showSnackBar(SnackBar(content: Text('Deleted "${row.name}".')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typesAsync = ref.watch(labourTypesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Labour Types'),
        actions: [
          IconButton(
            tooltip: 'Add type',
            icon: const Icon(Icons.add, size: 26),
            onPressed: () => _addOrEdit(context, ref, null),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AsyncView<List<LabourTypeDef>>(
        value: typesAsync,
        data: (rows) {
          if (rows.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'No labour types yet. Tap + to add one (e.g. "Mason", "Electrician").'),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (_, i) {
              final r = rows[i];
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.engineering_outlined),
                  ),
                  title: Text(r.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: _subtitle(r),
                  isThreeLine: r.description != null || r.defaultDailyRate != null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _addOrEdit(context, ref, r),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _delete(context, ref, r),
                      ),
                    ],
                  ),
                  onTap: () => _addOrEdit(context, ref, r),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Add type'),
      ),
    );
  }

  Widget? _subtitle(LabourTypeDef r) {
    final parts = <String>[
      if (r.description != null && r.description!.isNotEmpty) r.description!,
      if (r.defaultDailyRate != null)
        'Default daily rate: ${fmtMoney(r.defaultDailyRate!)}',
    ];
    if (parts.isEmpty) return null;
    return Text(parts.join('\n'), maxLines: 2, overflow: TextOverflow.ellipsis);
  }
}

class _LabourTypeForm extends StatefulWidget {
  const _LabourTypeForm({this.initial});
  final LabourTypeDef? initial;

  @override
  State<_LabourTypeForm> createState() => _LabourTypeFormState();
}

class _LabourTypeFormState extends State<_LabourTypeForm> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _rate;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _name = TextEditingController(text: r?.name ?? '');
    _desc = TextEditingController(text: r?.description ?? '');
    _rate = TextEditingController(
        text: r?.defaultDailyRate?.toStringAsFixed(0) ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _rate.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final rate = double.tryParse(_rate.text.replaceAll(',', ''));
    Navigator.pop(
      context,
      LabourTypeDef(
        id: widget.initial?.id ?? '',
        name: name,
        description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
        defaultDailyRate: rate,
        createdAt: widget.initial?.createdAt ?? DateTime.now().toUtc(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.initial;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(initial == null ? 'New Labour Type' : 'Edit Labour Type',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name *',
                hintText: 'e.g. Mason, Electrician, Plumber',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _desc,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Skill Description (optional)',
                hintText: 'e.g. Brickwork, plastering, wall finishing',
              ),
              maxLines: 2,
              minLines: 1,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Default Daily Rate (optional)',
                prefixText: 'Rs ',
                helperText:
                    'Shown as a hint in the transaction form — the actual amount is always entered manually',
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _submit,
              child: Text(initial == null ? 'Create' : 'Save'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
