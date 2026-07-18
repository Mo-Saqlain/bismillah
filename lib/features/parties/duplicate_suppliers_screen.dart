import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/formatters.dart';
import '../../data/models/party.dart';
import '../../providers/providers.dart';

/// Finds active suppliers that share a name (entered separately on two devices
/// before sync converged) and merges them into one. Merging re-points every
/// ledger and inventory row onto the kept supplier and archives the rest — no
/// data is lost whichever record you keep; only its name/phone/metadata
/// survives, and the running balances consolidate onto one party.
class DuplicateSuppliersScreen extends ConsumerStatefulWidget {
  const DuplicateSuppliersScreen({super.key});

  @override
  ConsumerState<DuplicateSuppliersScreen> createState() =>
      _DuplicateSuppliersScreenState();
}

class _DuplicateSuppliersScreenState
    extends ConsumerState<DuplicateSuppliersScreen> {
  List<List<Party>>? _groups;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = await ref.read(entityRepoProvider.future);
    final groups = await repo.duplicateSupplierGroups();
    if (mounted) setState(() => _groups = groups);
  }

  Future<void> _mergeGroup(List<Party> group) async {
    final messenger = ScaffoldMessenger.of(context);
    final keep = await showDialog<Party>(
      context: context,
      builder: (ctx) => _KeepPickerDialog(group: group),
    );
    if (keep == null) return;

    setState(() => _busy = true);
    try {
      final repo = await ref.read(entityRepoProvider.future);
      await repo.mergeSuppliers(
        keepId: keep.id,
        duplicateIds: group.map((p) => p.id).toList(),
      );
      bumpLedger(ref);
      await _load();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Merged ${group.length - 1} duplicate(s) into "${keep.name}".',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return Scaffold(
      appBar: AppBar(title: const Text('Merge Duplicate Suppliers')),
      body: groups == null
          ? const Center(child: CircularProgressIndicator())
          : groups.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.verified_outlined,
                            size: 56, color: Colors.green),
                        SizedBox(height: 12),
                        Text(
                          'No duplicate suppliers found.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(4, 4, 4, 12),
                      child: Text(
                        'These active suppliers share a name. Merging keeps one '
                        'record, moves all transactions onto it, and archives '
                        'the rest. Nothing is deleted.',
                      ),
                    ),
                    for (final g in groups)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                g.first.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 16),
                              ),
                              const SizedBox(height: 6),
                              for (final p in g)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 2),
                                  child: Text(
                                    '• ${[
                                      if (p.phone != null &&
                                          p.phone!.isNotEmpty)
                                        'Ph ${p.phone}',
                                      if (p.category != null) p.category!.label,
                                      'added ${fmtDate(p.createdAt)}',
                                    ].join(' · ')}',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ),
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: FilledButton.icon(
                                  onPressed:
                                      _busy ? null : () => _mergeGroup(g),
                                  icon: const Icon(Icons.merge_type),
                                  label: Text('Merge ${g.length}'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}

/// Radio picker for which record survives a merge. Defaults to the oldest
/// (the group is passed oldest-first).
class _KeepPickerDialog extends StatefulWidget {
  const _KeepPickerDialog({required this.group});
  final List<Party> group;

  @override
  State<_KeepPickerDialog> createState() => _KeepPickerDialogState();
}

class _KeepPickerDialogState extends State<_KeepPickerDialog> {
  late Party _keep = widget.group.first;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Keep which record?'),
      content: RadioGroup<Party>(
        groupValue: _keep,
        onChanged: (v) => setState(() => _keep = v!),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'All transactions move onto the kept supplier; the others are '
                'archived.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(height: 8),
            for (final p in widget.group)
              RadioListTile<Party>(
                value: p,
                title: Text(p.name),
                subtitle: Text([
                  if (p.phone != null && p.phone!.isNotEmpty) 'Ph ${p.phone}',
                  'added ${fmtDate(p.createdAt)}',
                ].join(' · ')),
                dense: true,
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _keep),
          child: const Text('Merge'),
        ),
      ],
    );
  }
}
