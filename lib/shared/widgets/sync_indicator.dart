import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/data/sync/sync_service.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';

/// App-bar sync control. Doubles as a status light and a tap-to-sync
/// button: the icon reflects the live [SyncStatus], and tapping it kicks a
/// forced manual sync (so it works even when background sync is toggled off
/// in Settings). Hidden entirely when Supabase isn't configured in this
/// build — there's nothing to sync to.
class SyncIndicator extends ConsumerWidget {
  const SyncIndicator({super.key, this.status});
  final AsyncValue<SyncStatus>? status;

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Syncing with Supabase…'),
        duration: Duration(seconds: 1),
      ),
    );
    final svc = await ref.read(syncServiceFutureProvider.future);
    // force: true so a tap still syncs even when the background toggle is off.
    await svc.syncNow(force: true);
    final s = svc.currentStatus;
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(switch (s.state) {
          SyncState.idle => 'Synced ✓',
          SyncState.offline => 'Offline — will sync when back online',
          SyncState.error => 'Sync failed: ${s.message ?? 'unknown error'}',
          _ => 'Sync finished',
        }),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!SupabaseConfig.configured) return const SizedBox.shrink();
    final AsyncValue<SyncStatus> effectiveStatus =
        status ?? ref.watch(syncStatusProvider);
    return effectiveStatus.when(
      loading: () => const SizedBox.shrink(),
      error: (error, stack) => IconButton(
        icon: const Icon(Icons.cloud_off),
        tooltip: 'Tap to retry sync',
        onPressed: () => _sync(context, ref),
      ),
      data: (SyncStatus s) {
        final (IconData icon, String label) = switch (s.state) {
          SyncState.idle => (Icons.cloud_done, 'Synced'),
          SyncState.syncing => (Icons.cloud_sync, 'Syncing…'),
          SyncState.error => (Icons.cloud_off, 'Sync error'),
          SyncState.offline => (Icons.cloud_off, 'Offline'),
          SyncState.disabled => (Icons.cloud_outlined, 'Local'),
        };
        final syncing = s.state == SyncState.syncing;
        return IconButton(
          tooltip:
              'Sync now · $label${s.pending > 0 ? ' · ${s.pending} pending' : ''}',
          onPressed: syncing ? null : () => _sync(context, ref),
          icon: syncing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon),
        );
      },
    );
  }
}
