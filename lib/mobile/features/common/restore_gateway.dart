import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/app_restart.dart';
import 'package:bismillah_constructions/shared/data/db/local_db.dart';
import 'package:bismillah_constructions/shared/data/services/backup_service.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';
import 'package:bismillah_constructions/mobile/features/auth/login_screen.dart';
import 'package:bismillah_constructions/mobile/features/home/home_screen.dart';

/// Thin startup gate that sits in front of [HomeScreen] and [LoginScreen].
///
/// Handles silent auto-restore on fresh installs, then routes to [LoginScreen]
/// if no user is authenticated, or [HomeScreen] if active session exists.
class RestoreGateway extends ConsumerStatefulWidget {
  const RestoreGateway({super.key});

  @override
  ConsumerState<RestoreGateway> createState() => _RestoreGatewayState();
}

class _RestoreGatewayState extends ConsumerState<RestoreGateway> {
  bool _ready = false;
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

      if (!_autoRestoreAttempted) {
        _autoRestoreAttempted = true;
        final backupPath =
            await BackupService.findLatestBackupForAutoRestore();
        if (backupPath != null) {
          await _silentRestore(backupPath);
          return;
        }
      }
    } catch (_) {}

    if (mounted) setState(() => _ready = true);
  }

  Future<void> _silentRestore(String backupPath) async {
    try {
      final dbPath = LocalDb.instance.dbPath;
      if (dbPath == null) {
        if (mounted) setState(() => _ready = true);
        return;
      }
      await LocalDb.instance.reinitialize();
      await File(backupPath).copy(dbPath);
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

    final authState = ref.watch(authNotifierProvider);

    return authState.when(
      data: (user) {
        if (user == null) {
          return const LoginScreen();
        }
        return const HomeScreen();
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const LoginScreen(),
    );
  }
}
