import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/core/formatters.dart';
import 'package:bismillah_constructions/shared/data/sync/sync_service.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';
import 'package:bismillah_constructions/mobile/features/home/home_screen.dart' show kPillNavReservedHeight;
import 'package:bismillah_constructions/mobile/features/settings/backups_list_screen.dart';
import 'package:bismillah_constructions/mobile/features/settings/change_log_screen.dart';
import 'package:bismillah_constructions/mobile/features/settings/recent_errors_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  DateTime? _lastBackup;
  String? _backupFolder;
  bool _backupBusy = false;

  @override
  void initState() {
    super.initState();
    _refreshBackupTime();
    _resolveBackupFolder();
  }

  Future<void> _refreshBackupTime() async {
    final svc = await ref.read(backupServiceProvider.future);
    final t = await svc.lastBackupAt();
    if (!mounted) return;
    setState(() => _lastBackup = t);
  }

  /// Mirrors `BackupService.backupDirectory()` so the user can see (and copy)
  /// where their backups are written.
  Future<void> _resolveBackupFolder() async {
    Directory? base;
    try {
      if (Platform.isAndroid) {
        final dirs = await getExternalStorageDirectories(
          type: StorageDirectory.documents,
        );
        if (dirs != null && dirs.isNotEmpty) base = dirs.first;
      }
      base ??= await getApplicationDocumentsDirectory();
    } catch (_) {
      /* fall through */
    }
    if (base == null) return;
    if (!mounted) return;
    setState(() => _backupFolder = p.join(base!.path, 'Bismillah_Backups'));
  }

  Future<void> _importBackup() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // FileType.any avoids Android SAF rejecting the non-standard `.db`
      // MIME type (which silently throws on some devices and never opens
      // the picker). We validate the extension ourselves below.
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        dialogTitle: 'Select a Bismillah .db backup',
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;
      final path = picked.path;
      if (path == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Could not read file path — try copying the backup to internal storage first.',
            ),
          ),
        );
        return;
      }
      final lower = picked.name.toLowerCase();
      if (!lower.endsWith('.db')) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Not a .db backup file: ${picked.name}. Pick a file ending in .db.',
            ),
          ),
        );
        return;
      }

      if (!mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(
            Icons.warning_amber,
            color: Theme.of(ctx).colorScheme.error,
            size: 36,
          ),
          title: const Text('Replace your current database?'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Importing "${picked.name}" will:'),
                const SizedBox(height: 12),
                const _BulletLine(
                  'WIPE every transaction, project, supplier, bank, '
                  'wallet, material type and setting that is currently '
                  'in this app.',
                ),
                const _BulletLine(
                  'REPLACE all of it with whatever the picked .db file '
                  'contains. The import is a full overwrite, not a '
                  'merge — anything not in the picked file is gone.',
                ),
                const _BulletLine(
                  'Save your existing database as a "<dbfile>.before_import" '
                  'snapshot first, so you can use Settings → "Undo last '
                  'import" to roll back if you change your mind.',
                ),
                const _BulletLine(
                  'Require an app restart afterwards to load the new data.',
                ),
                const SizedBox(height: 12),
                Text(
                  'Only proceed if you trust this .db file and you have '
                  'already exported anything you might want to keep from '
                  'the current install.',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace database'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      if (!mounted) return;

      setState(() => _backupBusy = true);
      final backup = await ref.read(backupServiceProvider.future);
      final err = await backup.importBackup(path);
      if (!mounted) return;
      setState(() => _backupBusy = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            err == null
                ? 'Imported. Restart the app to load the new database.'
                : 'Import failed: $err',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e, st) {
      debugPrint('Import backup failed: $e\n$st');
      if (!mounted) return;
      setState(() => _backupBusy = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Import error: $e'),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  Future<void> _runBackupNow() async {
    setState(() => _backupBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    final svc = await ref.read(backupServiceProvider.future);
    final ok = await svc.runBackup();
    await _refreshBackupTime();
    if (!mounted) return;
    setState(() => _backupBusy = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Backup written to the backup folder'
              : 'Backup failed — check storage permissions / free space',
        ),
      ),
    );
  }

  Future<void> _shareLatestBackup() async {
    setState(() => _backupBusy = true);
    final messenger = ScaffoldMessenger.of(context);
    final svc = await ref.read(backupServiceProvider.future);
    final ok = await svc.shareLatestBackup();
    if (!mounted) return;
    setState(() => _backupBusy = false);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No backup available to share — try again'),
        ),
      );
    }
  }

  Future<void> _testFolder() async {
    final messenger = ScaffoldMessenger.of(context);
    final svc = await ref.read(backupServiceProvider.future);
    final reason = await svc.testBackupFolder();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          reason == null
              ? 'Backup folder is writable ✓'
              : 'Folder test failed: $reason',
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _rollbackImport() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Undo last import?'),
        content: const Text(
          'Restores the database from the snapshot saved before your last import. '
          'The current database will be saved as "<dbfile>.before_rollback" '
          'in case you change your mind. You must restart the app afterwards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Roll back'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!mounted) return;

    setState(() => _backupBusy = true);
    final svc = await ref.read(backupServiceProvider.future);
    final err = await svc.rollbackLastImport();
    if (!mounted) return;
    setState(() => _backupBusy = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          err ?? 'Rolled back. Restart the app to load the previous database.',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);

    final currentUser = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        // Bottom padding clears the floating pill nav.
        padding: const EdgeInsets.fromLTRB(
          12,
          12,
          12,
          12 + kPillNavReservedHeight,
        ),
        children: [
          _SectionTitle('User Account'),
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor:
                    currentUser?.isAdmin == true ? Colors.indigo : Colors.blueGrey,
                child: Icon(
                  currentUser?.isAdmin == true
                      ? Icons.admin_panel_settings
                      : Icons.person,
                  color: Colors.white,
                ),
              ),
              title: Text(
                currentUser?.username ?? 'Guest User',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                'Role: ${(currentUser?.role ?? 'User').toUpperCase()}',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: OutlinedButton.icon(
                onPressed: () async {
                  await ref.read(authNotifierProvider.notifier).logout();
                },
                icon: const Icon(Icons.logout, size: 18, color: Colors.red),
                label: const Text('Log Out', style: TextStyle(color: Colors.red)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _SectionTitle('Appearance'),
          Card(
            child: Column(
              children: [
                _ThemeOption(
                  label: 'System default',
                  value: ThemeMode.system,
                  current: mode,
                  onSelect: (v) =>
                      ref.read(themeModeProvider.notifier).setMode(v),
                ),
                _ThemeOption(
                  label: 'Light',
                  value: ThemeMode.light,
                  current: mode,
                  onSelect: (v) =>
                      ref.read(themeModeProvider.notifier).setMode(v),
                ),
                _ThemeOption(
                  label: 'Dark',
                  value: ThemeMode.dark,
                  current: mode,
                  onSelect: (v) =>
                      ref.read(themeModeProvider.notifier).setMode(v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SectionTitle('Backup & Export'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('Backup folder'),
                  subtitle: Text(
                    _backupFolder ?? 'Resolving…',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: _backupFolder == null
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.bug_report, size: 18),
                              tooltip: 'Test write access',
                              onPressed: _backupBusy ? null : _testFolder,
                            ),
                            IconButton(
                              icon: const Icon(Icons.copy, size: 18),
                              tooltip: 'Copy path',
                              onPressed: () async {
                                final messenger = ScaffoldMessenger.of(context);
                                await Clipboard.setData(
                                  ClipboardData(text: _backupFolder!),
                                );
                                messenger.showSnackBar(
                                  const SnackBar(content: Text('Path copied')),
                                );
                              },
                            ),
                          ],
                        ),
                ),
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('Last backup'),
                  subtitle: Text(
                    _lastBackup == null ? 'Never' : fmtDateTime(_lastBackup!),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.backup),
                  title: const Text('Run backup now'),
                  subtitle: const Text(
                    'Saves to the backup folder above (survives uninstall on Android)',
                  ),
                  trailing: _backupBusy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _backupBusy ? null : _runBackupNow,
                ),
                ListTile(
                  leading: const Icon(Icons.share),
                  title: const Text('Share latest backup'),
                  subtitle: const Text(
                    'Send the .db file via WhatsApp / Gmail / Drive',
                  ),
                  trailing: _backupBusy
                      ? null
                      : const Icon(Icons.chevron_right),
                  onTap: _backupBusy ? null : _shareLatestBackup,
                ),
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: const Text('Import backup'),
                  subtitle: const Text(
                    'Pick a .db file and replace the current database',
                  ),
                  trailing: _backupBusy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _backupBusy ? null : _importBackup,
                ),
                ListTile(
                  leading: const Icon(Icons.list_alt),
                  title: const Text('Backup history'),
                  subtitle: const Text(
                    'Browse, share, restore or delete past backups',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const BackupsListScreen(),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.undo),
                  title: const Text('Undo last import'),
                  subtitle: const Text(
                    'Roll back to the snapshot saved before your last import',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _backupBusy ? null : _rollbackImport,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (SupabaseConfig.configured) ...[
            _SectionTitle('Cloud Sync'),
            const _CloudSyncCard(),
            const SizedBox(height: 12),
          ],
          _SectionTitle('Danger Zone'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.cleaning_services, color: Colors.red),
              title: const Text('Wipe All Data (Local & Cloud)'),
              subtitle: const Text(
                'Permanently clears all projects, transactions, inventory, notes and cloud data across all connected devices.',
              ),
              onTap: () async {
                final repo = await ref.read(entityRepoProvider.future);
                final tenant = await repo.tenantIdOrNull();
                if (!context.mounted) return;
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => _WipeAllDataDialog(tenantId: tenant),
                );
                if (confirm != true) return;
                if (!context.mounted) return;
                try {
                  final messenger = ScaffoldMessenger.of(context);
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('Wiping all local and cloud data across all devices…'),
                      duration: Duration(seconds: 2),
                    ),
                  );

                  if (SupabaseConfig.configured) {
                    final syncSvc = await ref.read(syncServiceFutureProvider.future);
                    await syncSvc.wipeCloudData();
                  }

                  final ledger = await ref.read(ledgerRepoProvider.future);
                  await ledger.wipeAllData();
                  await repo.resetPushCursors();
                  await repo.resetPullCursors();

                  bumpLedger(ref);
                  if (!context.mounted) return;
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('All local & cloud data successfully wiped across all devices ✓'),
                      backgroundColor: Colors.red,
                      duration: Duration(seconds: 4),
                    ),
                  );
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Wipe failed: $e')),
                    );
                  }
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          _SectionTitle('Audit'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.fact_check),
              title: const Text('Change Log'),
              subtitle: const Text(
                'New entries, edits, deletes and archives. Export to CSV.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ChangeLogScreen()),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: Icon(
                Icons.bug_report_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Recent Errors'),
              subtitle: const Text(
                'In-app log of framework, async and widget errors '
                'caught this session.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const RecentErrorsScreen()),
              ),
            ),
          ),
          const SizedBox(height: 24),
          // The launcher icon is the only place the brand mark appears.
          // The footer keeps just the wordmark so the screen still feels
          // signed.
          Center(
            child: Text(
              'Bismillah',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

/// Bullet row used in the Import warning dialog. Pulled out so the dialog
/// stays readable and indents stay consistent across all four bullets.
class _BulletLine extends StatelessWidget {
  const _BulletLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6, right: 8),
            child: Icon(Icons.circle, size: 6),
          ),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.label,
    required this.value,
    required this.current,
    required this.onSelect,
  });
  final String label;
  final ThemeMode value;
  final ThemeMode current;
  final ValueChanged<ThemeMode> onSelect;

  @override
  Widget build(BuildContext context) {
    final selected = current == value;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      title: Text(label),
      onTap: () => onSelect(value),
    );
  }
}

/// Settings card for Supabase cloud sync. Shown only when
/// [SupabaseConfig.configured] is true at build time. Owner sees:
///   * On/off toggle.
///   * Live sync status + last sync timestamp + pending count.
///   * Manual "Sync now" button.
///   * Tenant ID with copy + paste (for sharing the dataset with a
///     second device).
class _CloudSyncCard extends ConsumerStatefulWidget {
  const _CloudSyncCard();

  @override
  ConsumerState<_CloudSyncCard> createState() => _CloudSyncCardState();
}

class _CloudSyncCardState extends ConsumerState<_CloudSyncCard> {
  bool? _enabled;
  String? _tenantId;
  bool _busy = false;
  bool _checking = false;
  bool _repulling = false;
  bool _repushing = false;
  bool _diagBusy = false;
  SupabaseHealth? _health;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = await ref.read(entityRepoProvider.future);
    final enabled = await repo.cloudSyncEnabled();
    final tenant = await repo.tenantIdOrNull();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _tenantId = tenant;
    });
  }

  Future<void> _setEnabled(bool v) async {
    final repo = await ref.read(entityRepoProvider.future);
    await repo.setCloudSyncEnabled(v);
    if (!mounted) return;
    setState(() => _enabled = v);
    if (v) {
      // Kick a sync straight away so the user gets visible feedback
      // that the toggle actually did something.
      final svc = await ref.read(syncServiceFutureProvider.future);
      unawaited(svc.syncNow());
    }
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    try {
      final svc = await ref.read(syncServiceFutureProvider.future);
      // force: true so a manual sync still runs even when the background
      // sync toggle is off.
      await svc.syncNow(force: true);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkService() async {
    setState(() => _checking = true);
    try {
      final svc = await ref.read(syncServiceFutureProvider.future);
      final health = await svc.checkService();
      if (!mounted) return;
      setState(() => _health = health);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _fullRepull() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _repulling = true);
    try {
      final svc = await ref.read(syncServiceFutureProvider.future);
      await svc.fullRepull();
      await _load();
      final s = svc.currentStatus;
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(switch (s.state) {
            SyncState.idle => 'Re-pulled everything from the cloud ✓',
            SyncState.offline => 'Offline — will re-pull when back online',
            SyncState.error =>
              'Re-pull failed: ${s.message ?? 'unknown error'}',
            _ => 'Re-pull finished',
          }),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _repulling = false);
    }
  }

  Future<void> _fullRepush() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _repushing = true);
    try {
      final svc = await ref.read(syncServiceFutureProvider.future);
      await svc.fullRepush();
      await _load();
      final s = svc.currentStatus;
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(switch (s.state) {
            SyncState.idle => 'Re-pushed everything to the cloud ✓',
            SyncState.offline => 'Offline — will re-push when back online',
            SyncState.error =>
              'Re-push failed: ${s.message ?? 'unknown error'}',
            _ => 'Re-push finished',
          }),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _repushing = false);
    }
  }

  Future<void> _showDiagnostics() async {
    setState(() => _diagBusy = true);
    List<SyncTableDiag> rows;
    try {
      final svc = await ref.read(syncServiceFutureProvider.future);
      rows = await svc.diagnostics();
    } finally {
      if (mounted) setState(() => _diagBusy = false);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _SyncDiagnosticsDialog(rows: rows),
    );
  }

  Future<void> _editTenantId() async {
    final ctrl = TextEditingController(text: _tenantId ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.fingerprint, size: 36),
        title: const Text('Set tenant ID'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Paste the UUID copied from your other device so both '
              'phones see the same data. Leave blank to keep the '
              'current value.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Tenant UUID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Changing this on a device that already has data WILL NOT '
              'move existing rows — they remain tagged with the previous '
              'tenant on push. Set this before the first sync on a new '
              'device.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final raw = ctrl.text.trim();
    if (raw.isEmpty) return;
    final repo = await ref.read(entityRepoProvider.future);
    await repo.setTenantId(raw);
    if (!mounted) return;
    setState(() => _tenantId = raw);
  }

  String _stateLabel(SyncState s) => switch (s) {
    SyncState.idle => 'Idle',
    SyncState.syncing => 'Syncing…',
    SyncState.error => 'Error',
    SyncState.offline => 'Offline',
    SyncState.disabled => 'Disabled',
  };

  Color? _healthColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (_health?.state) {
      null => null,
      SupabaseHealthState.ok => Colors.green,
      SupabaseHealthState.offline => scheme.onSurfaceVariant,
      SupabaseHealthState.notConfigured => scheme.onSurfaceVariant,
      SupabaseHealthState.error => scheme.error,
    };
  }

  String _healthSubtitle() {
    final h = _health;
    if (h == null) {
      return 'Ping your Supabase project to confirm it is reachable';
    }
    return switch (h.state) {
      SupabaseHealthState.ok =>
        'Service reachable ✓ (${h.latency!.inMilliseconds} ms)',
      SupabaseHealthState.offline => h.message ?? 'This device is offline',
      SupabaseHealthState.notConfigured =>
        h.message ?? 'Supabase not configured in this build',
      SupabaseHealthState.error => 'Unreachable: ${h.message}',
    };
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(syncStatusProvider);
    return Card(
      child: Column(
        children: [
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.cloud_sync_outlined),
            title: const Text('Cloud sync to Supabase'),
            subtitle: const Text(
              'Push every write to your Supabase project. Required '
              'for second-device sync.',
            ),
            value: _enabled ?? true,
            onChanged: _enabled == null ? null : _setEnabled,
          ),
          const Divider(height: 1),
          status.when(
            loading: () => const ListTile(
              leading: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('Connecting…'),
            ),
            error: (e, _) => ListTile(
              leading: const Icon(Icons.cloud_off),
              title: const Text('Sync status unavailable'),
              subtitle: Text('$e'),
            ),
            data: (s) => ListTile(
              leading: Icon(switch (s.state) {
                SyncState.idle => Icons.cloud_done_outlined,
                SyncState.syncing => Icons.cloud_sync_outlined,
                SyncState.error => Icons.cloud_off,
                SyncState.offline => Icons.cloud_off,
                SyncState.disabled => Icons.cloud_outlined,
              }),
              title: Text(_stateLabel(s.state)),
              subtitle: Text(
                [
                  if (s.lastSyncAt != null)
                    'Last sync: ${fmtDateTime(s.lastSyncAt!)}'
                  else
                    'Not synced yet',
                  if (s.pending > 0) '${s.pending} pending',
                  if (s.message != null) s.message!,
                ].join(' · '),
              ),
            ),
          ),
          ListTile(
            leading: Icon(switch (_health?.state) {
              null => Icons.network_check,
              SupabaseHealthState.ok => Icons.check_circle_outline,
              SupabaseHealthState.offline => Icons.wifi_off,
              SupabaseHealthState.notConfigured => Icons.help_outline,
              SupabaseHealthState.error => Icons.error_outline,
            }, color: _healthColor(context)),
            title: const Text('Check Supabase service'),
            subtitle: Text(_healthSubtitle()),
            trailing: _checking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _checking ? null : _checkService,
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('Sync now'),
            subtitle: const Text(
              'Push local changes, then pull rows from other devices. '
              'Works even when background sync is off.',
            ),
            trailing: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _busy ? null : _syncNow,
          ),
          ListTile(
            leading: const Icon(Icons.analytics_outlined),
            title: const Text('Sync diagnostics'),
            subtitle: const Text(
              'Compare row counts on this phone vs the cloud, per table — '
              'shows exactly what is and isn\'t synced.',
            ),
            trailing: _diagBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _diagBusy ? null : _showDiagnostics,
          ),
          ListTile(
            leading: const Icon(Icons.cloud_download_outlined),
            title: const Text('Re-pull everything from cloud'),
            subtitle: const Text(
              'Re-download every row for this tenant. Safe — never '
              'overwrites data already on this phone. Use when the cloud '
              'has projects/transactions this device is missing.',
            ),
            trailing: _repulling
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _repulling ? null : _fullRepull,
          ),
          ListTile(
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('Re-push everything to cloud'),
            subtitle: const Text(
              'Re-upload every row from this phone. Use on the device that '
              'created a project/supplier which is missing on another device '
              '(fixes "orphaned row" sync errors). Safe — upserts by id.',
            ),
            trailing: _repushing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _repushing ? null : _fullRepush,
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('Tenant ID'),
            subtitle: Text(
              _tenantId ?? 'Generated on first sync',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_tenantId != null)
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy',
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(ClipboardData(text: _tenantId!));
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Tenant ID copied')),
                      );
                    },
                  ),
                IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: 'Set to a different tenant',
                  onPressed: _editTenantId,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Read-only census of local vs cloud row counts, per synced table. Turns
/// "sync feels wrong" into concrete numbers and a plain-language diagnosis.
class _SyncDiagnosticsDialog extends StatelessWidget {
  const _SyncDiagnosticsDialog({required this.rows});
  final List<SyncTableDiag> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tenantMismatch = rows.any(
      (r) => (r.remoteTenant ?? 0) == 0 && (r.remoteAll ?? 0) > 0,
    );
    final missingLocally = rows.any(
      (r) => r.remoteTenant != null && r.remoteTenant! > r.local,
    );

    Widget cell(
      String text, {
      int flex = 2,
      bool header = false,
      TextAlign align = TextAlign.end,
    }) => Expanded(
      flex: flex,
      child: Text(
        text,
        textAlign: align,
        style: TextStyle(
          fontSize: 12,
          fontWeight: header ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
    );

    return AlertDialog(
      title: const Text('Sync diagnostics'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                cell('Table', flex: 4, header: true, align: TextAlign.start),
                cell('Here', header: true),
                cell('Cloud', header: true),
                cell('All', header: true),
              ],
            ),
            const Divider(),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    cell(r.table, flex: 4, align: TextAlign.start),
                    cell('${r.local}'),
                    cell(r.remoteTenant?.toString() ?? '—'),
                    cell(r.remoteAll?.toString() ?? '—'),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            Text(
              tenantMismatch
                  ? 'Your Supabase project holds rows under a DIFFERENT tenant '
                        'id ("Cloud" is 0 while "All" is not). Set the shared '
                        'Tenant ID below to match your other device, then re-pull.'
                  : missingLocally
                  ? 'The cloud has rows this phone is missing ("Cloud" > '
                        '"Here"). Tap "Re-pull everything from cloud".'
                  : 'This phone already has everything the cloud holds for '
                        'your tenant. Anything not showing in a list is '
                        'archived or deleted, not lost.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
            ),
            const SizedBox(height: 8),
            Text(
              'Here = on this phone · Cloud = your tenant on Supabase · '
              'All = every tenant in the project.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Multi-step, phrase-confirmed destructive wipe dialog.
/// Requires checking the acknowledgment checkbox AND typing "DELETE EVERYTHING"
/// before the destructive action button becomes active.
class _WipeAllDataDialog extends StatefulWidget {
  const _WipeAllDataDialog({required this.tenantId});
  final String? tenantId;

  @override
  State<_WipeAllDataDialog> createState() => _WipeAllDataDialogState();
}

class _WipeAllDataDialogState extends State<_WipeAllDataDialog> {
  static const _requiredPhrase = 'DELETE EVERYTHING';
  final _controller = TextEditingController();
  bool _understoodCheckbox = false;

  bool get _canWipe =>
      _understoodCheckbox && _controller.text.trim() == _requiredPhrase;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      scrollable: true,
      icon: Icon(Icons.warning_amber_rounded, size: 44, color: scheme.error),
      title: const Text('⚠️ DANGER ZONE: Wipe All Data'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.errorContainer.withOpacity(0.4),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.error.withOpacity(0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CRITICAL WARNING',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: scheme.error,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '• ALL local database records (projects, suppliers, banks, transactions, inventory, notes, follow-ups) will be PERMANENTLY DELETED from this device.\n'
                  '• ALL cloud backups & Supabase remote database tables for this tenant will be DELETED from the cloud.\n'
                  '• ALL connected phones, tablets & desktop apps sharing this Tenant ID will be WIPED as well.\n'
                  '• THIS ACTION CANNOT BE UNDONE.',
                  style: TextStyle(fontSize: 12.5, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (widget.tenantId != null) ...[
            Text(
              'Target Tenant ID: ${widget.tenantId}',
              style: TextStyle(fontSize: 11.5, color: scheme.outline),
            ),
            const SizedBox(height: 10),
          ],
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _understoodCheckbox,
            activeColor: scheme.error,
            onChanged: (v) => setState(() => _understoodCheckbox = v ?? false),
            title: const Text(
              'I understand that all local and cloud data will be PERMANENTLY DESTROYED across ALL connected devices.',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'To confirm, type "$_requiredPhrase" below:',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: _requiredPhrase,
              border: const OutlineInputBorder(),
              errorText: _controller.text.isNotEmpty &&
                      _controller.text.trim() != _requiredPhrase
                  ? 'Phrase must match "$_requiredPhrase" exactly'
                  : null,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: _canWipe ? () => Navigator.pop(context, true) : null,
          icon: const Icon(Icons.delete_forever),
          label: const Text('WIPE EVERYTHING'),
        ),
      ],
    );
  }
}
