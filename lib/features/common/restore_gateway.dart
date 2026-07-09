import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_restart.dart';
import '../../data/db/local_db.dart';
import '../../data/services/backup_service.dart';
import '../../providers/providers.dart';
import '../home/home_screen.dart';

/// Thin startup gate that sits in front of [HomeScreen].
///
/// Backups live in external app-scoped storage (Bismillah_Backups folder)
/// which survives app uninstall on most Android devices. So on a fresh
/// install where the internal DB is empty, we **silently** copy the most
/// recent backup over the internal DB — no dialog, no prompt.
///
/// On every subsequent cold start the DB has data, so this gate just opens
/// the DB and goes straight to HomeScreen. The user can still run a manual
/// import from Settings → Import backup whenever they want.
class RestoreGateway extends ConsumerStatefulWidget {
  const RestoreGateway({super.key});

  @override
  ConsumerState<RestoreGateway> createState() => _RestoreGatewayState();
}

class _RestoreGatewayState extends ConsumerState<RestoreGateway> {
  bool _ready = false;
  // Static flag survives the restartApp() ProviderScope rebuild. We only
  // ever attempt one silent auto-restore per app launch — if the backup file
  // is bad and the DB is still empty after a copy, we proceed to HomeScreen
  // rather than looping forever.
  static bool _autoRestoreAttempted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startup());
  }

  Future<void> _startup() async {
    try {
      final db = await ref.read(dbProvider.future);

      final projCount =
          ((await db.rawQuery('SELECT COUNT(*) AS c FROM projects'))
                  .first['c'] as int?) ??
              0;
      final entryCount =
          ((await db.rawQuery('SELECT COUNT(*) AS c FROM journal_entries'))
                  .first['c'] as int?) ??
              0;

      if (projCount > 0 || entryCount > 0) {
        // DB already has data — normal cold start.
        if (mounted) setState(() => _ready = true);
        return;
      }

      // DB is empty. If a backup exists AND we haven't already tried this
      // launch, silently restore it before showing HomeScreen. The static
      // flag survives the restartApp() ProviderScope rebuild so a broken
      // backup never loops.
      if (!_autoRestoreAttempted) {
        _autoRestoreAttempted = true;
        final backupPath =
            await BackupService.findLatestBackupForAutoRestore();
        if (backupPath != null) {
          await _silentRestore(backupPath);
          return; // restartApp() rebuilds the tree
        }
      }
    } catch (_) {
      // Any error — just open HomeScreen with whatever data exists.
    }

    if (mounted) setState(() => _ready = true);
  }

  Future<void> _silentRestore(String backupPath) async {
    try {
      final dbPath = LocalDb.instance.dbPath;
      if (dbPath == null) {
        if (mounted) setState(() => _ready = true);
        return;
      }
      // Close the empty in-process DB so the file handle is released.
      await LocalDb.instance.reinitialize();
      // Overwrite the empty DB file with the backup's content.
      await File(backupPath).copy(dbPath);
      // Trigger a full ProviderScope rebuild so every provider reopens the
      // freshly restored file from scratch.
      restartApp();
    } catch (_) {
      if (mounted) setState(() => _ready = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return const HomeScreen();
  }
}
