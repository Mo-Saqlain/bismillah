import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/models/follow_up.dart';
import '../../data/models/project.dart';
import '../../providers/providers.dart';
import '../common/async_view.dart';

/// Customer recovery / payment-promise tracker. Forward-looking notes that
/// say "Asif sahab promised to clear Rs 200k by next Thursday." Resolves
/// into a ledger entry — or gets cancelled — but in itself isn't an
/// accounting transaction.
class FollowUpsScreen extends ConsumerStatefulWidget {
  const FollowUpsScreen({super.key});

  @override
  ConsumerState<FollowUpsScreen> createState() => _FollowUpsScreenState();
}

class _FollowUpsScreenState extends ConsumerState<FollowUpsScreen> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final list = _showArchived
        ? ref.watch(archivedFollowUpsProvider)
        : ref.watch(pendingFollowUpsProvider);
    final projects = ref.watch(projectsProvider);

    return Scaffold(
      appBar: AppBar(
        title:
            Text(_showArchived ? 'Resolved Follow-ups' : 'Recovery Follow-ups'),
        actions: [
          IconButton(
            tooltip: _showArchived ? 'Show pending' : 'Show resolved',
            icon: Icon(_showArchived
                ? Icons.pending_actions
                : Icons.history),
            onPressed: () => setState(() => _showArchived = !_showArchived),
          ),
        ],
      ),
      floatingActionButton: _showArchived
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openEditor(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('New follow-up'),
            ),
      body: AsyncView(
        value: list,
        data: (items) {
          if (items.isEmpty) {
            return _Empty(
              showArchived: _showArchived,
              onAdd: () => _openEditor(context, ref),
            );
          }
          final projectsMap = projects.maybeWhen(
            data: (ps) => {for (final p in ps) p.id: p},
            orElse: () => <String, Project>{},
          );
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final f = items[i];
              return _FollowUpTile(
                followUp: f,
                projectName: f.projectId == null
                    ? null
                    : projectsMap[f.projectId]?.name,
                onResolve: () async {
                  final repo = await ref.read(entityRepoProvider.future);
                  await repo.resolveFollowUp(f.id);
                  bumpLedger(ref);
                },
                onReopen: () async {
                  final repo = await ref.read(entityRepoProvider.future);
                  await repo.reopenFollowUp(f.id);
                  bumpLedger(ref);
                },
                onCancel: () async {
                  final repo = await ref.read(entityRepoProvider.future);
                  await repo.cancelFollowUp(f.id);
                  bumpLedger(ref);
                },
                onEdit: () => _openEditor(context, ref, existing: f),
                onDelete: () async {
                  final repo = await ref.read(entityRepoProvider.future);
                  await repo.deleteFollowUp(f.id);
                  bumpLedger(ref);
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, WidgetRef ref,
      {FollowUp? existing}) async {
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final noteCtrl = TextEditingController(text: existing?.note ?? '');
    final amountCtrl = TextEditingController(
        text: existing?.amountEstimate?.toStringAsFixed(0) ?? '');
    DateTime? expected = existing?.expectedDate;
    FollowUpPriority priority = existing?.priority ?? FollowUpPriority.medium;
    String? projectId = existing?.projectId;

    final projects = await ref.read(projectsProvider.future);

    if (!context.mounted) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
          left: 16,
          right: 16,
          top: 16,
        ),
        child: StatefulBuilder(
          builder: (ctx, setSheetState) => SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(existing == null ? 'New follow-up' : 'Edit follow-up',
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: titleCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Title *',
                    helperText:
                        'e.g. "Asif sahab to clear Rs 200k of Site A"',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: projectId,
                  decoration: const InputDecoration(
                      labelText: 'Project (optional)'),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('— None —')),
                    for (final p in projects)
                      DropdownMenuItem(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: (v) => setSheetState(() => projectId = v),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: amountCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Expected amount (optional)',
                          prefixText: 'Rs ',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]')),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final now = DateTime.now();
                          final picked = await showDatePicker(
                            context: ctx,
                            firstDate:
                                now.subtract(const Duration(days: 365)),
                            lastDate:
                                now.add(const Duration(days: 365 * 3)),
                            initialDate: expected ?? now,
                          );
                          if (picked != null) {
                            setSheetState(() => expected = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Expected date',
                          ),
                          child: Text(
                            expected == null
                                ? 'Tap to pick'
                                : fmtDate(expected!),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<FollowUpPriority>(
                  initialValue: priority,
                  decoration: const InputDecoration(labelText: 'Priority'),
                  items: FollowUpPriority.values
                      .map((p) =>
                          DropdownMenuItem(value: p, child: Text(p.label)))
                      .toList(),
                  onChanged: (v) =>
                      setSheetState(() => priority = v ?? priority),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteCtrl,
                  maxLines: 3,
                  minLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.pop(sheetCtx, true),
                  child: const Text('Save'),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved != true) return;
    final title = titleCtrl.text.trim();
    if (title.isEmpty) return;
    final amount = double.tryParse(amountCtrl.text);
    final repo = await ref.read(entityRepoProvider.future);
    if (existing == null) {
      await repo.addFollowUp(
        title: title,
        note: noteCtrl.text,
        projectId: projectId,
        expectedDate: expected,
        priority: priority,
        amountEstimate: amount,
      );
    } else {
      await repo.updateFollowUp(
        existing.id,
        title: title,
        note: noteCtrl.text,
        expectedDate: expected,
        priority: priority,
        amountEstimate: amount,
      );
    }
    bumpLedger(ref);
  }
}

class _FollowUpTile extends StatelessWidget {
  const _FollowUpTile({
    required this.followUp,
    required this.projectName,
    required this.onResolve,
    required this.onReopen,
    required this.onCancel,
    required this.onEdit,
    required this.onDelete,
  });

  final FollowUp followUp;
  final String? projectName;
  final VoidCallback onResolve;
  final VoidCallback onReopen;
  final VoidCallback onCancel;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final overdue = followUp.isOverdue();
    final scheme = Theme.of(context).colorScheme;
    final isPending = followUp.status == FollowUpStatus.pending;

    return Card(
      color: overdue ? scheme.errorContainer : null,
      child: ListTile(
        leading: _PriorityBadge(
          priority: followUp.priority,
          overdue: overdue,
        ),
        title: Text(
          followUp.title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            decoration: isPending ? null : TextDecoration.lineThrough,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (projectName != null)
              Text('Project: $projectName',
                  style: const TextStyle(fontSize: 12)),
            if (followUp.amountEstimate != null)
              Text('Amount: ${fmtMoney(followUp.amountEstimate!)}',
                  style: const TextStyle(fontSize: 12)),
            if (followUp.expectedDate != null)
              Text(
                'Expected: ${fmtDate(followUp.expectedDate!)}'
                '${overdue ? "  — OVERDUE" : ""}',
                style: TextStyle(
                  fontSize: 12,
                  color: overdue
                      ? BalanceColors.negative(context)
                      : null,
                  fontWeight: overdue ? FontWeight.w700 : null,
                ),
              ),
            if (followUp.note != null && followUp.note!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(followUp.note!,
                    style: const TextStyle(fontSize: 12)),
              ),
            if (followUp.status == FollowUpStatus.resolved &&
                followUp.resolvedAt != null)
              Text('Resolved ${fmtDate(followUp.resolvedAt!)}',
                  style: const TextStyle(fontSize: 12)),
            if (followUp.status == FollowUpStatus.cancelled &&
                followUp.resolvedAt != null)
              Text('Cancelled ${fmtDate(followUp.resolvedAt!)}',
                  style: const TextStyle(fontSize: 12)),
          ],
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          itemBuilder: (_) => [
            if (isPending)
              const PopupMenuItem(
                  value: 'resolve', child: Text('Mark resolved')),
            if (isPending)
              const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
            if (!isPending)
              const PopupMenuItem(value: 'reopen', child: Text('Reopen')),
            const PopupMenuItem(value: 'edit', child: Text('Edit')),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
          onSelected: (v) => switch (v) {
            'resolve' => onResolve(),
            'reopen' => onReopen(),
            'cancel' => onCancel(),
            'edit' => onEdit(),
            'delete' => onDelete(),
            _ => null,
          },
        ),
        onTap: onEdit,
      ),
    );
  }
}

class _PriorityBadge extends StatelessWidget {
  const _PriorityBadge({required this.priority, required this.overdue});
  final FollowUpPriority priority;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = overdue
        ? scheme.error
        : switch (priority) {
            FollowUpPriority.high => Colors.deepOrange,
            FollowUpPriority.medium => scheme.primary,
            FollowUpPriority.low => Colors.grey,
          };
    return CircleAvatar(
      backgroundColor: color.withValues(alpha: 0.15),
      foregroundColor: color,
      child: Icon(overdue
          ? Icons.warning_amber_rounded
          : switch (priority) {
              FollowUpPriority.high => Icons.priority_high,
              FollowUpPriority.medium => Icons.outbound,
              FollowUpPriority.low => Icons.low_priority,
            }),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.showArchived, required this.onAdd});
  final bool showArchived;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(showArchived ? Icons.history : Icons.pending_actions,
                size: 56, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
                showArchived
                    ? 'No resolved or cancelled follow-ups yet.'
                    : 'No pending follow-ups.',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              showArchived
                  ? 'Resolved follow-ups stay here for reference.'
                  : 'Capture verbal payment promises and chase commitments '
                      'that haven\'t become ledger entries yet.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (!showArchived) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: const Text('Add the first follow-up'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
