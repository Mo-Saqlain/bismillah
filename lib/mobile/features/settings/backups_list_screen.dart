import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/app_restart.dart';
import 'package:bismillah_constructions/shared/core/formatters.dart';
import 'package:bismillah_constructions/shared/data/db/local_db.dart';
import 'package:bismillah_constructions/shared/data/services/backup_service.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';

bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// Snapshot of everything the backups screen renders in one shot.
class _BackupData {
  final List<BackupFile> files;
  final String folder;
  final DateTime? lastBackup;
  const _BackupData(this.files, this.folder, this.lastBackup);
}

/// Browse, create, import, share and restore on-device backups, and (desktop)
/// choose where backups are stored. The "latest" pointer is locked from
/// deletion so the one-tap restore flow always has something to grab.
class BackupsListScreen extends ConsumerStatefulWidget {
  const BackupsListScreen({super.key});

  @override
  ConsumerState<BackupsListScreen> createState() => _BackupsListScreenState();
}

class _BackupsListScreenState extends ConsumerState<BackupsListScreen> {
  late Future<_BackupData> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_BackupData> _load() async {
    final svc = await ref.read(backupServiceProvider.future);
    final files = await svc.listBackups();
    final dir = await svc.backupDirectory();
    final last = await svc.lastBackupAt();
    return _BackupData(files, dir?.path ?? '(unavailable)', last);
  }

  void _refresh() {
    if (!mounted) return;
    // Block body (not `=> _future = _load()`) so the setState callback
    // returns void, not the assigned Future.
    setState(() {
      _future = _load();
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Create ────────────────────────────────────────────────────────────────
  Future<void> _runBackup() async {
    setState(() => _busy = true);
    final svc = await ref.read(backupServiceProvider.future);
    final ok = await svc.runBackup();
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(ok ? 'Backup created.' : 'Backup failed — check the folder is writable.');
    _refresh();
  }

  // ── Import an external .db ──────────────────────────────────────────────────
  Future<void> _importFile() async {
    final res = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose a Bismillah backup (.db) file',
      type: FileType.custom,
      allowedExtensions: const ['db'],
    );
    final path = res?.files.single.path;
    if (path == null) return;
    final ok = await _confirm(
      'Import this backup?',
      'The current database will be REPLACED with:\n\n$path\n\n'
          'A rollback copy of your current data is saved first. '
          'The app will reload automatically after import.',
      'Import',
    );
    if (ok) await _applyBackup(path);
  }

  // ── Change backup folder (desktop) ──────────────────────────────────────────
  Future<void> _changeFolder() async {
    final dir = await FilePicker.platform
        .getDirectoryPath(dialogTitle: 'Choose a backup folder');
    if (dir == null) return;
    final svc = await ref.read(backupServiceProvider.future);
    await svc.setBackupDir(dir);
    _snack('Backup folder set to:\n$dir');
    _refresh();
  }

  Future<void> _resetFolder() async {
    final svc = await ref.read(backupServiceProvider.future);
    await svc.setBackupDir(null);
    _snack('Reverted to the default backup folder.');
    _refresh();
  }

  // ── Save a copy / share ─────────────────────────────────────────────────────
  Future<void> _shareOrSave(BackupFile b) async {
    if (_isDesktop) {
      var name = b.isLatest ? 'bismillah_backup.db' : b.name;
      final dest = await FilePicker.platform.saveFile(
        dialogTitle: 'Save a copy of this backup',
        fileName: name,
        type: FileType.custom,
        allowedExtensions: const ['db'],
      );
      if (dest == null) return;
      var out = dest;
      if (!out.toLowerCase().endsWith('.db')) out = '$out.db';
      try {
        await File(b.path).copy(out);
        _snack('Saved copy to:\n$out');
      } catch (e) {
        _snack('Could not save copy: $e');
      }
      return;
    }
    final svc = await ref.read(backupServiceProvider.future);
    final ok = await svc.shareBackup(b.path);
    if (!ok) _snack('File not found — refresh the list.');
  }

  // ── Delete ──────────────────────────────────────────────────────────────────
  Future<void> _delete(BackupFile b) async {
    if (b.isLatest) return;
    final ok = await _confirm(
      'Delete this backup?',
      '${b.name}\n${_fmtSize(b.sizeBytes)} · ${fmtDateTime(b.modifiedAt)}\n\nThis cannot be undone.',
      'Delete',
      destructive: true,
    );
    if (!ok) return;
    final svc = await ref.read(backupServiceProvider.future);
    final deleted = await svc.deleteBackup(b.path);
    _snack(deleted ? 'Deleted ${b.name}' : 'Could not delete file');
    _refresh();
  }

  // ── Restore ───────────────────────────────────────────────────────────────
  Future<void> _restore(BackupFile b) async {
    final ok = await _confirm(
      'Restore from this backup?',
      'The current database will be REPLACED with:\n\n${b.name}\n\n'
          'A rollback copy of your current data is saved first. '
          'The app will reload automatically after restore.',
      'Restore',
    );
    if (ok) await _applyBackup(b.path);
  }

  /// Close the live DB (so Windows can replace the file), import, then hot
  /// restart the whole provider tree so the new database loads without a
  /// manual app restart.
  Future<void> _applyBackup(String path) async {
    setState(() => _busy = true);
    final svc = await ref.read(backupServiceProvider.future);
    final reason = await svc.validateBackupFile(path);
    if (reason != null) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Not a valid backup: $reason');
      return;
    }
    try {
      await LocalDb.instance.reinitialize();
      final err = await svc.importBackup(path);
      if (err != null) {
        if (!mounted) return;
        setState(() => _busy = false);
        _snack('Restore failed: $err');
        return;
      }
      // Rebuild the whole tree against the freshly restored file.
      restartApp();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Restore failed: $e');
    }
  }

  Future<bool> _confirm(String title, String body, String action,
      {bool destructive = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
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
        title: const Text('Backups'),
        actions: [
          IconButton(
            tooltip: 'Run backup now',
            icon: const Icon(Icons.backup_outlined),
            onPressed: _busy ? null : _runBackup,
          ),
          IconButton(
            tooltip: 'Import a .db file',
            icon: const Icon(Icons.file_open_outlined),
            onPressed: _busy ? null : _importFile,
          ),
          if (_isDesktop)
            IconButton(
              tooltip: 'Change backup folder',
              icon: const Icon(Icons.folder_open_outlined),
              onPressed: _busy ? null : _changeFolder,
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: FutureBuilder<_BackupData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          final data = snap.data!;
          return Column(
            children: [
              _header(data),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              const Divider(height: 1),
              Expanded(
                child: data.files.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'No backups yet.\n\nUse "Run backup now" above to create one.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: data.files.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) => _row(data.files[i]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(_BackupData data) {
    final scheme = Theme.of(context).colorScheme;
    final last = data.lastBackup == null
        ? 'never'
        : fmtDateTime(data.lastBackup!.toLocal());
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_outlined, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(data.folder,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
              if (_isDesktop)
                TextButton(
                  onPressed: _busy ? null : _resetFolder,
                  child: const Text('Default'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.schedule, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text('Last backup: $last',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const Spacer(),
              Text('${data.files.where((f) => !f.isLatest).length} snapshot(s)',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(BackupFile b) {
    final subtitle = '${_fmtSize(b.sizeBytes)} · ${fmtDateTime(b.modifiedAt)}';
    return ListTile(
      leading: Icon(
        b.isLatest ? Icons.star : Icons.archive_outlined,
        color: b.isLatest ? Theme.of(context).colorScheme.primary : null,
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
            case 'save':
              _shareOrSave(b);
            case 'restore':
              _restore(b);
            case 'delete':
              _delete(b);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'save',
            child: Text(_isDesktop ? 'Save a copy…' : 'Share'),
          ),
          const PopupMenuItem(value: 'restore', child: Text('Restore from this')),
          if (!b.isLatest)
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}
