import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../data/services/backup_service.dart';
import '../../providers/providers.dart';

/// Browse every on-device backup file. Per-row actions: share, restore,
/// delete. The "latest" pointer is locked from deletion so the one-tap
/// share/restore flow always has something to grab.
class BackupsListScreen extends ConsumerStatefulWidget {
  const BackupsListScreen({super.key});

  @override
  ConsumerState<BackupsListScreen> createState() => _BackupsListScreenState();
}

class _BackupsListScreenState extends ConsumerState<BackupsListScreen> {
  late Future<List<BackupFile>> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<BackupFile>> _load() async {
    final svc = await ref.read(backupServiceProvider.future);
    return svc.listBackups();
  }

  void _refresh() {
    setState(() => _future = _load());
  }

  Future<void> _share(BackupFile b) async {
    final svc = await ref.read(backupServiceProvider.future);
    final ok = await svc.shareBackup(b.path);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File not found — refresh the list.')),
      );
    }
  }

  Future<void> _delete(BackupFile b) async {
    if (b.isLatest) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this backup?'),
        content: Text(
          '${b.name}\n${_fmtSize(b.sizeBytes)} · ${fmtDateTime(b.modifiedAt)}\n\nThis cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final svc = await ref.read(backupServiceProvider.future);
    final deleted = await svc.deleteBackup(b.path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(deleted ? 'Deleted ${b.name}' : 'Could not delete file'),
      ),
    );
    _refresh();
  }

  Future<void> _restore(BackupFile b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from this backup?'),
        content: Text(
          'The current local database will be REPLACED with:\n\n${b.name}\n\n'
          'Your existing DB will be saved as "<dbfile>.before_import" so you can roll back from Settings.\n\n'
          'You must restart the app after restore to load the new data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final svc = await ref.read(backupServiceProvider.future);
    final err = await svc.importBackup(b.path);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          err == null
              ? 'Restored. Restart the app to load the database.'
              : 'Restore failed: $err',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)}MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Backup History'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<BackupFile>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final list = snap.data ?? const <BackupFile>[];
          if (list.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No backups yet.\n\nGo back and tap "Run backup now" to create one.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final b = list[i];
              final subtitle =
                  '${_fmtSize(b.sizeBytes)} · '
                  '${fmtDateTime(b.modifiedAt)}';
              return ListTile(
                leading: Icon(
                  b.isLatest ? Icons.star : Icons.archive_outlined,
                  color: b.isLatest
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(
                  b.isLatest ? 'Latest snapshot' : b.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(subtitle),
                trailing: PopupMenuButton<String>(
                  enabled: !_busy,
                  onSelected: (v) {
                    switch (v) {
                      case 'share':
                        _share(b);
                        break;
                      case 'restore':
                        _restore(b);
                        break;
                      case 'delete':
                        _delete(b);
                        break;
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'share', child: Text('Share')),
                    const PopupMenuItem(
                      value: 'restore',
                      child: Text('Restore from this'),
                    ),
                    if (!b.isLatest)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete'),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
