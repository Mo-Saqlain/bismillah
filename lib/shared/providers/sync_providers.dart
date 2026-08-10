import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/data/services/backup_service.dart';
import 'package:bismillah_constructions/shared/data/sync/sync_service.dart';
import 'package:bismillah_constructions/shared/providers/db_providers.dart';

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

/// Wires every local mutation to an immediate cloud push. Watched once at
/// app boot so the listeners stay alive for the lifetime of the app.
///
/// Two triggers, because writes reach the DB two ways:
///   * Ledger commits fire the repo's commit hook directly (covers every
///     posted transaction, including any non-UI writer).
///   * Entity mutations (suppliers, projects, banks, material/labour types,
///     notes, follow-ups) don't post to the ledger, but the UI bumps
///     `ledgerVersionProvider` after each one — so a listener on that version
///     pushes those too. Without it, an edited supplier or a new note would
///     only sync on the next poll instead of instantly.
///
/// Both use `pushOnly: true`: outbound changes must upload immediately, while
/// inbound changes already stream in over Realtime, so there's no need to pull
/// on every keystroke-level edit. `syncNow` coalesces, so the overlap between
/// the two triggers (a transaction fires both) is harmless.
final commitSyncWiringProvider = FutureProvider<void>((ref) async {
  final ledger = await ref.watch(ledgerRepoProvider.future);
  final sync = await ref.watch(syncServiceFutureProvider.future);

  void onCommit() {
    unawaited(sync.syncNow(pushOnly: true));
  }

  ledger.addCommitListener(onCommit);
  ref.onDispose(() => ledger.removeCommitListener(onCommit));

  ref.listen<int>(ledgerVersionProvider, (previous, next) {
    unawaited(sync.syncNow(pushOnly: true));
  });
});

/// Bumps `ledgerVersionProvider` whenever the sync engine applies a remote
/// change — from a Realtime event or a pull — so every open screen refetches
/// live. This is the inbound half of real-time sync: [commitSyncWiringProvider]
/// pushes local edits up, this pulls remote edits into the UI. Watched once at
/// app boot.
final remoteRefreshWiringProvider = FutureProvider<void>((ref) async {
  final sync = await ref.watch(syncServiceFutureProvider.future);
  final sub = sync.dataChanged.listen((_) {
    ref.read(ledgerVersionProvider.notifier).update((v) => v + 1);
  });
  ref.onDispose(sub.cancel);
});
