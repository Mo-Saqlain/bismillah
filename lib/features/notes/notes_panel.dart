import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/models/note.dart';
import '../../providers/providers.dart';

/// Inline notes block attached to a project or supplier. Renders a header
/// with an "Add note" button, then pinned notes (highlighted) followed by
/// the rest in newest-first order. Used on the Site Snapshot screen and
/// supplier detail flows.
class NotesPanel extends ConsumerWidget {
  const NotesPanel({
    super.key,
    required this.entityType,
    required this.entityId,
    this.title = 'Notes',
  });

  final NoteEntityType entityType;
  final String entityId;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(notesForProvider(
        (type: entityType, entityId: entityId)));

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          )),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                  onPressed: () => _openEditor(context, ref),
                ),
              ],
            ),
            notesAsync.when(
              data: (notes) {
                if (notes.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No notes yet. Capture supplier reliability, payment '
                      'behaviour, quality issues or anything else worth '
                      'remembering.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final n in notes)
                      _NoteTile(
                        note: n,
                        onPin: () async {
                          final repo =
                              await ref.read(entityRepoProvider.future);
                          await repo.toggleNotePin(n.id, !n.isPinned);
                          bumpLedger(ref);
                        },
                        onEdit: () => _openEditor(context, ref, existing: n),
                        onDelete: () async {
                          final repo =
                              await ref.read(entityRepoProvider.future);
                          await repo.deleteNote(n.id);
                          bumpLedger(ref);
                        },
                      ),
                  ],
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(8),
                child: Text('Failed to load notes: $e'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, WidgetRef ref,
      {Note? existing}) async {
    final ctrl = TextEditingController(text: existing?.body ?? '');
    bool pinned = existing?.isPinned ?? false;
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
                Text(existing == null ? 'New note' : 'Edit note',
                    style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  maxLines: 5,
                  minLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Note',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Pin to top'),
                  value: pinned,
                  onChanged: (v) => setSheetState(() => pinned = v),
                ),
                const SizedBox(height: 8),
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
    final body = ctrl.text.trim();
    if (body.isEmpty) return;
    final repo = await ref.read(entityRepoProvider.future);
    if (existing == null) {
      await repo.addNote(
        type: entityType,
        entityId: entityId,
        body: body,
        pinned: pinned,
      );
    } else {
      await repo.updateNoteBody(existing.id, body);
      if (existing.isPinned != pinned) {
        await repo.toggleNotePin(existing.id, pinned);
      }
    }
    bumpLedger(ref);
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({
    required this.note,
    required this.onPin,
    required this.onEdit,
    required this.onDelete,
  });

  final Note note;
  final VoidCallback onPin;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: note.isPinned ? scheme.primaryContainer : scheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(note.body),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  fmtDateTime(note.updatedAt ?? note.createdAt),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                    note.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 18),
                tooltip: note.isPinned ? 'Unpin' : 'Pin',
                onPressed: onPin,
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined, size: 18),
                tooltip: 'Edit',
                onPressed: onEdit,
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: 'Delete',
                onPressed: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
