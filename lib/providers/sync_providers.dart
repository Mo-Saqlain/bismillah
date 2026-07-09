import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/backup_service.dart';
import '../data/sync/sync_service.dart';
import 'db_providers.dart';

final syncServiceFutureProvider = FutureProvider<SyncService>((ref) async {
  final ledger = await ref.watch(ledgerRepoProvider.future);
  final entities = await ref.watch(entityRepoProvider.future);
  final svc = SyncService(ledger, entities);
  ref.onDispose(svc.dispose);
  svc.start();
  return svc;
});

final syncStatusProvider = StreamProvider<SyncStatus>((ref) async* {
  final svc = await ref.watch(syncServiceFutureProvider.future);
  yield SyncStatus.initial;
  yield* svc.status;
});

final backupServiceProvider = FutureProvider<BackupService>((ref) async {
  final repo = await ref.watch(entityRepoProvider.future);
  final svc = BackupService(repo);
  // Make sure a stable device id exists for the audit log.
  unawaited(svc.ensureDeviceId());
  return svc;
});

/// Trigger a silent backup once on app boot when older than 6 hours.
final backupBootCheckProvider = FutureProvider<void>((ref) async {
  final svc = await ref.watch(backupServiceProvider.future);
  await svc.maybeRunSilentBackup();
});

/// Wires every successful ledger commit to a sync push. Watched once at
/// app boot so the listener stays alive for the lifetime of the app.
final commitSyncWiringProvider = FutureProvider<void>((ref) async {
  final ledger = await ref.watch(ledgerRepoProvider.future);
  final sync = await ref.watch(syncServiceFutureProvider.future);

  void onCommit() {
    unawaited(sync.syncNow());
  }

  ledger.addCommitListener(onCommit);
  ref.onDispose(() => ledger.removeCommitListener(onCommit));
});
