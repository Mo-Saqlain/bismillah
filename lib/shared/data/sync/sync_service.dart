import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/core/error_reporter.dart';
import 'package:bismillah_constructions/shared/data/repositories/entity_repository.dart';
import 'package:bismillah_constructions/shared/data/repositories/ledger_repository.dart';

enum SyncState { idle, syncing, error, offline, disabled }

/// Outcome of a one-shot reachability probe against the Supabase project.
enum SupabaseHealthState { ok, offline, notConfigured, error }

class SupabaseHealth {
  final SupabaseHealthState state;
  final String? message;
  final Duration? latency;
  const SupabaseHealth(this.state, {this.message, this.latency});
}

class SyncStatus {
  final SyncState state;
  final int pending;
  final String? message;
  final DateTime? lastSyncAt;

  const SyncStatus({
    required this.state,
    required this.pending,
    this.message,
    this.lastSyncAt,
  });

  static const initial = SyncStatus(state: SyncState.idle, pending: 0);
}

/// Per-table row counts for the sync diagnostics screen.
///
///   * [local]        — rows in this device's SQLite DB.
///   * [remoteTenant] — rows on Supabase tagged with THIS device's tenant
///                      id (null if the count couldn't be fetched).
///   * [remoteAll]    — rows on Supabase for every tenant (open RLS lets us
///                      see them; null if it couldn't be fetched).
///
/// Reading the three together explains "missing" data:
///   * `remoteTenant == 0` but `remoteAll > 0` → server data is under a
///     DIFFERENT tenant id (fix by matching the shared Tenant ID).
///   * `remoteTenant > local` → this device never pulled some rows; a
///     "re-pull everything" fixes it.
///   * `local >= remoteTenant` → nothing missing from the cloud.
class SyncTableDiag {
  final String table;
  final int local;
  final int? remoteTenant;
  final int? remoteAll;
  const SyncTableDiag({
    required this.table,
    required this.local,
    required this.remoteTenant,
    required this.remoteAll,
  });
}

/// True when [server] is a strictly newer instant than [local] — the
/// last-write-wins decision the pull uses to overwrite a local row.
///
/// Both are parsed to `DateTime` before comparing: server rows carry a
/// `+00:00` offset while local rows use a trailing `Z` (and differing
/// sub-second precision), so a raw string compare would be wrong; comparing
/// instants is correct regardless of format. A null local always loses; a
/// null (or unparseable) server never wins. Public so the reconciliation
/// rule can be unit-tested directly.
bool serverTimestampIsNewer(String? server, String? local) {
  if (server == null) return false;
  if (local == null) return true;
  final s = DateTime.tryParse(server);
  final l = DateTime.tryParse(local);
  if (s == null) return false;
  if (l == null) return true;
  return s.isAfter(l);
}

/// Tables that mirror to Supabase. Order matters for **pull** — rows are
/// inserted in this order so foreign keys resolve (projects before
/// material_inventory, suppliers before journal_entries, etc.).
const _kSyncTables = <String>[
  'projects',
  'suppliers',
  'banks',
  'material_types',
  'labour_types',
  'counter_entities',
  'material_inventory',
  'journal_entries',
  'notes',
  'follow_ups',
];

/// Bismillah's cloud-sync engine.
///
/// Push: every local row whose `updated_at` exceeds the push cursor
/// for its table is upserted to Supabase, tagged with the operator's
/// `tenant_id`. Cursor advances to `max(updated_at)` on success.
///
/// Pull: every remote row whose `updated_at` exceeds the pull cursor
/// (and whose tenant matches) is candidate-inserted locally via
/// `INSERT OR IGNORE` — if the id already exists, the local row wins
/// and the pull row is dropped on the floor. This is the
/// "never destroy local writes" guarantee.
///
/// Soft-deletes propagate as ordinary writes: setting `is_deleted = 1`
/// fires the bump-updated trigger, push picks it up, the matching row
/// on the other device upserts to `is_deleted = 1` on the next pull.
///
/// Wire-up:
///   * `start()` — kicks off the connectivity listener + 2-minute ticker.
///   * `syncNow()` — manual or commit-driven; idempotent; safe to call
///     concurrently (a syncing call short-circuits the next one).
class SyncService {
  SyncService(this._ledger, this._entities);
  final LedgerRepository _ledger;
  final EntityRepository _entities;

  final _statusCtrl = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get status => _statusCtrl.stream;
  SyncStatus _last = SyncStatus.initial;
  SyncStatus get currentStatus => _last;

  /// Fires (with no payload) every time a pull or a Realtime event applies at
  /// least one remote row to local SQLite. A wiring provider listens to this
  /// and bumps `ledgerVersionProvider` so every open screen refetches — the
  /// piece that makes cross-device changes appear live instead of only after
  /// the next local edit.
  final _dataChangedCtrl = StreamController<void>.broadcast();
  Stream<void> get dataChanged => _dataChangedCtrl.stream;

  StreamSubscription? _connSub;
  Timer? _ticker;
  bool _syncing = false;

  /// Realtime subscription channels (one per synced table). Established once,
  /// on the first successful online sync, and torn down in [dispose].
  final List<RealtimeChannel> _channels = [];
  bool _realtimeSubscribed = false;

  void start() {
    if (!SupabaseConfig.configured) {
      _emit(const SyncStatus(
          state: SyncState.disabled,
          pending: 0,
          message: 'Supabase not configured — running local-only.'));
      return;
    }
    _connSub = Connectivity()
        .onConnectivityChanged
        .listen((_) => unawaited(syncNow()));
    // Safety-net poll. Realtime delivers remote changes within ~1s and local
    // mutations push immediately, so this is only a backstop for the rare case
    // Realtime drops (publication not enabled, socket lost) — kept short so
    // the app still feels near-live in that degraded mode.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => syncNow());
    unawaited(_bootSync());
  }

  /// First sync of the launch: force a full re-pull so a fresh — or any —
  /// install converges to the COMPLETE cloud dataset before Realtime takes
  /// over for live deltas. This is what guarantees "every device gets all the
  /// data" regardless of how stale its pull cursors were. Idempotent: pulls
  /// are last-write-wins, so re-downloading rows the device already has is a
  /// no-op.
  Future<void> _bootSync() async {
    try {
      if (await _entities.cloudSyncEnabled()) {
        await _entities.resetPullCursors();
      }
    } catch (_) {/* fall through to a normal sync */}
    await syncNow();
  }

  void dispose() {
    for (final c in _channels) {
      try {
        unawaited(Supabase.instance.client.removeChannel(c));
      } catch (_) {/* client may already be torn down */}
    }
    _channels.clear();
    _connSub?.cancel();
    _ticker?.cancel();
    _dataChangedCtrl.close();
    _statusCtrl.close();
  }

  /// Probes the Supabase project with a single lightweight round-trip.
  /// Confirms the device is online, the URL resolves, the anon key is
  /// accepted and the schema is reachable — without pulling real data.
  /// Independent of the cloud-sync toggle so the operator can check the
  /// service even while background sync is off.
  Future<SupabaseHealth> checkService() async {
    if (!SupabaseConfig.configured) {
      return const SupabaseHealth(SupabaseHealthState.notConfigured,
          message: 'Supabase URL / anon key not set in this build.');
    }
    final results = await Connectivity().checkConnectivity();
    final online = results.any((r) => r != ConnectivityResult.none);
    if (!online) {
      return const SupabaseHealth(SupabaseHealthState.offline,
          message: 'This device is offline.');
    }
    final sw = Stopwatch()..start();
    try {
      await Supabase.instance.client.from('projects').select('id').limit(1);
      sw.stop();
      return SupabaseHealth(SupabaseHealthState.ok, latency: sw.elapsed);
    } catch (e) {
      sw.stop();
      return SupabaseHealth(SupabaseHealthState.error, message: e.toString());
    }
  }

  /// Drains both push and pull for every syncing table. Safe to call
  /// from anywhere; concurrent calls are coalesced.
  ///
  /// [force] bypasses the cloud-sync toggle so the operator can trigger a
  /// one-shot manual sync from Settings even when background sync is off.
  /// The automatic triggers (ticker, connectivity, commit listener) never
  /// pass it, so they still respect the toggle.
  ///
  /// [pushOnly] uploads local changes but skips the pull pass. Used by the
  /// per-mutation trigger: outbound changes must reach the cloud instantly,
  /// but inbound changes already arrive via Realtime, so pulling on every
  /// keystroke-level edit would be wasted round-trips.
  Future<void> syncNow({bool force = false, bool pushOnly = false}) async {
    if (!SupabaseConfig.configured) return;
    // Fast path: the DB can be closed underneath us during a restore/restart
    // (LocalDb.reinitialize() closes it, then restartApp() rebuilds the
    // provider tree; the *old* SyncService's ticker may still fire in that
    // window). Skip if it's already closed — the outer catch below handles
    // the race where it closes mid-await.
    if (!_ledger.db.isOpen) return;
    if (_syncing) return;

    try {
      if (!force && !await _entities.cloudSyncEnabled()) {
        _emit(SyncStatus(
          state: SyncState.disabled,
          pending: 0,
          lastSyncAt: _last.lastSyncAt,
          message: 'Cloud sync disabled in Settings.',
        ));
        return;
      }

      final pending = await _countLocalPending();

      final results = await Connectivity().checkConnectivity();
      final online = results.any((r) => r != ConnectivityResult.none);
      if (!online) {
        _emit(SyncStatus(state: SyncState.offline, pending: pending));
        return;
      }

      _syncing = true;
      _emit(SyncStatus(state: SyncState.syncing, pending: pending));
      try {
        final tenantId = await _entities.ensureTenantId();
        final client = Supabase.instance.client;

        // One-time-per-install integrity backfill: force a full re-push so any
        // row stranded by a pre-sync / old-tenant push-cursor gap reaches the
        // server. This is what stops a parent from living only on one device
        // and orphaning its children elsewhere — it self-corrects on the first
        // sync after upgrade, with no operator action.
        await _ensurePushBackfill();

        for (final table in _kSyncTables) {
          await _pushTable(client, table, tenantId);
        }
        if (!pushOnly) {
          for (final table in _kSyncTables) {
            await _pullTable(client, table, tenantId);
          }
          // Retry any rows previously skipped for a missing FK parent — the
          // parent may have just arrived in the pulls above (or via a re-push
          // from the device that owns it). Runs last so parents are present.
          await _flushPending();
          // Establish the live Realtime subscriptions once the first full
          // pull has completed, so subsequent remote edits stream in live.
          await _ensureRealtime(client, tenantId);
        }

        _emit(SyncStatus(
          state: SyncState.idle,
          pending: 0,
          lastSyncAt: DateTime.now(),
        ));
      } finally {
        _syncing = false;
      }
    } catch (e) {
      _syncing = false;
      // A DB closed under us during a restore/restart is expected and
      // harmless — skip silently rather than spamming the error reporter.
      // Anything else is a real sync failure worth surfacing.
      if (_isDatabaseClosed(e)) return;
      _emit(SyncStatus(
        state: SyncState.error,
        pending: _last.pending,
        message: e.toString(),
        lastSyncAt: _last.lastSyncAt,
      ));
    }
  }

  /// A `database_closed` error means the DB was reinitialised under us during
  /// a restore/restart — expected, not a real failure. Checks the typed flag
  /// and the message so it's robust across sqflite versions.
  static bool _isDatabaseClosed(Object e) {
    if (e is DatabaseException && e.isDatabaseClosedError()) return true;
    return e.toString().contains('database_closed');
  }

  /// A foreign-key constraint violation (SQLITE_CONSTRAINT_FOREIGNKEY, code
  /// 787) — a pulled child row whose parent isn't present locally. Checked by
  /// result code and message so it's robust across sqflite versions.
  static bool _isForeignKeyError(Object e) {
    if (e is DatabaseException && e.getResultCode() == 787) return true;
    return e.toString().contains('FOREIGN KEY constraint failed');
  }

  /// Recovery action: clear the pull cursors, then run a full forced sync so
  /// every server row for this tenant is re-downloaded. Pulls are INSERT OR
  /// IGNORE, so local rows are never overwritten — this only back-fills rows
  /// the device never pulled. Bypasses the cloud-sync toggle.
  Future<void> fullRepull() async {
    await _entities.resetPullCursors();
    await syncNow(force: true);
  }

  /// One-shot per-table census of local vs remote row counts, for the
  /// Settings → Sync diagnostics screen. Purely read-only. Remote counts are
  /// left null on a network/query error so the UI shows "—" for that table
  /// rather than failing the whole report.
  Future<List<SyncTableDiag>> diagnostics() async {
    final out = <SyncTableDiag>[];
    if (!SupabaseConfig.configured) return out;
    final tenantId = await _entities.ensureTenantId();
    final client = Supabase.instance.client;
    final db = _ledger.db;

    for (final table in _kSyncTables) {
      final localRows =
          await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
      final local = ((localRows.first['c'] as num?) ?? 0).toInt();

      int? remoteTenant;
      int? remoteAll;
      try {
        final tenantRes =
            await client.from(table).select('id').eq('tenant_id', tenantId);
        remoteTenant = (tenantRes as List).length;
        final allRes = await client.from(table).select('id');
        remoteAll = (allRes as List).length;
      } catch (_) {/* leave remote counts null — table row shows a dash */}

      out.add(SyncTableDiag(
        table: table,
        local: local,
        remoteTenant: remoteTenant,
        remoteAll: remoteAll,
      ));
    }
    return out;
  }

  // ── Push ──────────────────────────────────────────────────────────────

  Future<void> _pushTable(
      SupabaseClient client, String table, String tenantId) async {
    final cursor = await _entities.pushCursor(table);
    final cursorStr = cursor?.toUtc().toIso8601String();

    final db = _ledger.db;
    final rows = cursorStr == null
        ? await db.query(table, orderBy: 'updated_at ASC')
        : await db.query(
            table,
            where: 'updated_at > ?',
            whereArgs: [cursorStr],
            orderBy: 'updated_at ASC',
          );
    if (rows.isEmpty) return;

    const batchSize = 200;
    String? maxSeen;
    for (var i = 0; i < rows.length; i += batchSize) {
      final slice = rows.sublist(i, (i + batchSize).clamp(0, rows.length));
      try {
        final payload = slice.map((r) => _toRemote(r, table, tenantId)).toList();
        await client.from(table).upsert(payload);
        for (final r in slice) {
          final u = r['updated_at'] as String?;
          if (u != null && (maxSeen == null || u.compareTo(maxSeen) > 0)) {
            maxSeen = u;
          }
        }
      } catch (e) {
        // Poison-pill outbox isolation: fall back to item-by-item push so one
        // failing row payload doesn't freeze the rest of the pending sync queue.
        for (final r in slice) {
          try {
            final singlePayload = _toRemote(r, table, tenantId);
            await client.from(table).upsert(singlePayload);
            final u = r['updated_at'] as String?;
            if (u != null && (maxSeen == null || u.compareTo(maxSeen) > 0)) {
              maxSeen = u;
            }
          } catch (itemError) {
            ErrorReporter.report(
              'Failed to push $table row ${r['id']}: $itemError',
              source: 'Sync',
            );
          }
        }
      }
    }
    if (maxSeen != null) {
      final parsed = DateTime.tryParse(maxSeen);
      if (parsed != null) await _entities.setPushCursor(table, parsed);
    }
  }

  // ── Pull ──────────────────────────────────────────────────────────────

  Future<void> _pullTable(
      SupabaseClient client, String table, String tenantId) async {
    final cursor = await _entities.pullCursor(table);
    final cursorStr =
        cursor?.toUtc().toIso8601String() ?? '1970-01-01T00:00:00Z';

    const pageSize = 500;
    String? maxSeen;
    int offset = 0;
    while (true) {
      final response = await client
          .from(table)
          .select()
          .eq('tenant_id', tenantId)
          .gt('updated_at', cursorStr)
          .order('updated_at', ascending: true)
          .range(offset, offset + pageSize - 1);

      final rows = (response as List).cast<Map<String, dynamic>>();
      if (rows.isEmpty) break;

      final applied = await _applyRemoteRows(table, rows);
      if (applied > 0) _dataChangedCtrl.add(null);

      for (final r in rows) {
        final u = r['updated_at'] as String?;
        if (u != null && (maxSeen == null || u.compareTo(maxSeen) > 0)) {
          maxSeen = u;
        }
      }

      if (rows.length < pageSize) break;
      offset += pageSize;
    }

    final finalMax = maxSeen;
    if (finalMax != null) {
      final parsed = DateTime.tryParse(finalMax);
      if (parsed != null) await _entities.setPullCursor(table, parsed);
    }
  }

  /// Applies remote rows to local SQLite under last-write-wins, returning how
  /// many actually inserted/updated. Shared by the pull pass and the Realtime
  /// handler so both use identical conflict rules.
  ///
  /// Last-write-wins: Supabase is the source of truth for the latest edit. A
  /// brand-new id inserts; an existing id is overwritten only when the server
  /// row's `updated_at` is strictly newer than the local one (so a genuine
  /// offline local edit isn't clobbered by a stale server copy). Edits and
  /// soft-deletes therefore propagate across devices while staying
  /// offline-capable. Safe against ping-pong: migration 0005 drops the
  /// server-side auto-bump trigger, so re-pushing a just-pulled row is a no-op
  /// upsert that doesn't change its timestamp.
  ///
  /// A child row (material_inventory / journal_entries) can arrive before its
  /// FK parent — the parent may not be on the server yet. Such a row is
  /// skipped (not aborting the batch) and buffered in `pending_pull` so a
  /// later sync re-inserts it the moment the parent lands (see _flushPending).
  Future<int> _applyRemoteRows(
      String table, List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return 0;
    final db = _ledger.db;
    final orphans = <Map<String, Object?>>[];
    var applied = 0;
    await db.transaction((txn) async {
      for (final r in rows) {
        final local = _fromRemote(r, table);
        final id = local['id'];
        try {
          final existing = await txn.query(table,
              columns: ['updated_at'],
              where: 'id = ?',
              whereArgs: [id],
              limit: 1);
          if (existing.isEmpty) {
            await txn.insert(table, local,
                conflictAlgorithm: ConflictAlgorithm.replace);
            applied++;
          } else if (serverTimestampIsNewer(local['updated_at'] as String?,
              existing.first['updated_at'] as String?)) {
            await txn.update(table, local, where: 'id = ?', whereArgs: [id]);
            applied++;
          }
        } catch (e) {
          if (_isForeignKeyError(e)) {
            orphans.add(local);
          } else {
            rethrow;
          }
        }
      }
    });
    if (orphans.isNotEmpty) await _bufferOrphans(table, orphans);
    return applied;
  }

  // ── Realtime (live inbound) ────────────────────────────────────────────

  /// Subscribe once to Postgres change events for every synced table, scoped
  /// to this tenant. Remote inserts/updates then stream into local SQLite
  /// within ~1s (soft-deletes arrive as ordinary UPDATEs). Requires the tables
  /// to be in the `supabase_realtime` publication (supabase/migrations/0006).
  /// If that publication step hasn't been applied the subscription is simply
  /// silent — the 30-second poll keeps things converging in that degraded mode.
  Future<void> _ensureRealtime(SupabaseClient client, String tenantId) async {
    if (_realtimeSubscribed) return;
    _realtimeSubscribed = true;
    for (final table in _kSyncTables) {
      final channel = client.channel('rt:$table');
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'tenant_id',
          value: tenantId,
        ),
        callback: (payload) {
          final rec = payload.newRecord;
          if (rec.isNotEmpty) {
            unawaited(_onRealtimeChange(table, Map<String, dynamic>.from(rec)));
          }
        },
      );
      channel.subscribe();
      _channels.add(channel);
    }
  }

  /// Handle a single Realtime row: apply it locally (LWW) and, if it actually
  /// changed something, signal the UI to refetch and flush any orphans it may
  /// have just unblocked. Pull cursors are intentionally NOT advanced here — a
  /// later poll re-touching the same row is a cheap no-op and avoids skipping a
  /// row if events arrive out of order.
  Future<void> _onRealtimeChange(
      String table, Map<String, dynamic> row) async {
    if (!_ledger.db.isOpen) return;
    try {
      final applied = await _applyRemoteRows(table, [row]);
      if (applied > 0) {
        _dataChangedCtrl.add(null);
        await _flushPending();
      }
    } catch (e) {
      if (!_isDatabaseClosed(e)) {
        ErrorReporter.report(e, source: 'Realtime');
      }
    }
  }

  // ── Orphan retry buffer (self-healing pull) ────────────────────────────

  /// Give up on a buffered orphan after this many failed retries so a truly
  /// unrecoverable row (parent genuinely deleted everywhere) can't grow the
  /// buffer or re-log forever. At the 2-minute tick that's ~hours of retries.
  static const _maxOrphanAttempts = 50;

  /// Persist rows skipped for a missing FK parent so a later sync can retry
  /// them. Keyed by (id, table); re-buffering an already-pending row just
  /// refreshes its payload, leaving the attempt count intact.
  Future<void> _bufferOrphans(
      String table, List<Map<String, Object?>> rows) async {
    final db = _ledger.db;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      for (final r in rows) {
        final id = r['id'];
        if (id == null) continue;
        final existing = await txn.query('pending_pull',
            columns: ['attempts'],
            where: 'id = ? AND table_name = ?',
            whereArgs: [id, table],
            limit: 1);
        if (existing.isEmpty) {
          await txn.insert('pending_pull', {
            'id': id,
            'table_name': table,
            'payload': jsonEncode(r),
            'attempts': 0,
            'first_seen': now,
          });
        } else {
          await txn.update(
            'pending_pull',
            {'payload': jsonEncode(r)},
            where: 'id = ? AND table_name = ?',
            whereArgs: [id, table],
          );
        }
      }
    });
  }

  /// Re-attempt every buffered orphan. A row that now inserts (its parent has
  /// arrived) is removed from the buffer; one that still fails has its attempt
  /// count bumped and is dropped once it exceeds [_maxOrphanAttempts]. Called
  /// at the end of every [syncNow], after the pulls that may supply parents.
  Future<void> _flushPending() async {
    final db = _ledger.db;
    final pending = await db.query('pending_pull', orderBy: 'first_seen ASC');
    if (pending.isEmpty) return;

    for (final p in pending) {
      final id = p['id'];
      final table = p['table_name'] as String;
      final Map<String, Object?> local;
      try {
        local =
            (jsonDecode(p['payload'] as String) as Map).cast<String, Object?>();
      } catch (_) {
        // Corrupt payload — nothing we can do with it; drop it.
        await db.delete('pending_pull',
            where: 'id = ? AND table_name = ?', whereArgs: [id, table]);
        continue;
      }

      try {
        await db.transaction((txn) async {
          final existing = await txn.query(table,
              columns: ['updated_at'],
              where: 'id = ?',
              whereArgs: [id],
              limit: 1);
          if (existing.isEmpty) {
            await txn.insert(table, local,
                conflictAlgorithm: ConflictAlgorithm.replace);
          } else if (serverTimestampIsNewer(local['updated_at'] as String?,
              existing.first['updated_at'] as String?)) {
            await txn.update(table, local, where: 'id = ?', whereArgs: [id]);
          }
        });
        await db.delete('pending_pull',
            where: 'id = ? AND table_name = ?', whereArgs: [id, table]);
      } catch (e) {
        if (!_isForeignKeyError(e)) rethrow;
        final attempts = ((p['attempts'] as num?) ?? 0).toInt() + 1;
        if (attempts >= _maxOrphanAttempts) {
          await db.delete('pending_pull',
              where: 'id = ? AND table_name = ?', whereArgs: [id, table]);
          ErrorReporter.report(
            'Gave up syncing $table row $id after $attempts tries — its parent '
            'never reached the cloud. Open the device that created it and use '
            'Settings → Cloud Sync → Re-push everything.',
            source: 'Sync',
          );
        } else {
          await db.update('pending_pull',
              {'attempts': attempts, 'last_error': e.toString()},
              where: 'id = ? AND table_name = ?', whereArgs: [id, table]);
        }
      }
    }
    // healed / dropped are intentionally not surfaced — a silent self-heal is
    // the desired behaviour; only a permanent give-up (above) is reported.
  }

  /// Recovery action: clear the push cursors, then force a full sync so every
  /// local row for this tenant is re-uploaded. Run this on the device that
  /// owns a parent which never reached the cloud (its children orphan on other
  /// devices). Upserts are idempotent, so this only back-fills the server.
  Future<void> fullRepush() async {
    await _entities.resetPushCursors();
    await syncNow(force: true);
  }

  /// Wipes all remote cloud records for the current tenant ID from Supabase.
  /// Deletes in reverse table dependency order so child foreign key rows are
  /// deleted before parents. When rows are deleted from Supabase Postgres,
  /// Postgres Realtime broadcasts DELETE events to all connected devices.
  Future<void> wipeCloudData() async {
    if (!SupabaseConfig.configured) return;
    try {
      final client = Supabase.instance.client;
      final tenantId = await _entities.ensureTenantId();
      for (final table in _kSyncTables.reversed) {
        await client.from(table).delete().eq('tenant_id', tenantId);
      }
      await _entities.resetPushCursors();
      await _entities.resetPullCursors();
    } catch (e, stack) {
      ErrorReporter.report('Cloud wipe failed: $e', stack: stack, source: 'Sync');
      rethrow;
    }
  }

  /// Bump this when a new build needs every install to re-push once (e.g. to
  /// backfill data stranded by an older, buggier sync). Stored per-install in
  /// `app_settings` (not synced), so each device runs the backfill exactly
  /// once regardless of what other devices have done.
  static const _pushBackfillMarker = 'orphan-fix-2026-08-b';

  Future<void> _ensurePushBackfill() async {
    const key = 'sync_push_backfill';
    final done = await _entities.getSetting(key);
    if (done == _pushBackfillMarker) return;
    await _entities.resetPushCursors();
    await _entities.setSetting(key, _pushBackfillMarker);
  }

  // ── Row shape conversion ──────────────────────────────────────────────

  /// Local row → Supabase payload. Adds tenant_id, drops the SQLite-only
  /// `synced` column (legacy from the v1 push design). `updated_at` is left
  /// as-is and is **client-authoritative**: the server-side auto-bump trigger
  /// is removed (migration 0005), so Postgres stores exactly the timestamp
  /// the writing device set. That keeps last-write-wins deterministic and
  /// stops a re-pushed pulled row from ping-ponging its timestamp.
  Map<String, Object?> _toRemote(
      Map<String, Object?> row, String table, String tenantId) {
    final out = Map<String, Object?>.from(row)..['tenant_id'] = tenantId;
    out.remove('synced');
    return out;
  }

  /// Supabase row → local INSERT payload. Strips `tenant_id` (local
  /// table doesn't have it), normalises timestamps to ISO-8601 strings,
  /// coerces numeric columns to `num`.
  Map<String, Object?> _fromRemote(
      Map<String, dynamic> row, String table) {
    final out = <String, Object?>{};
    for (final entry in row.entries) {
      if (entry.key == 'tenant_id') continue;
      out[entry.key] = _coerceFromRemote(entry.value);
    }
    if (table == 'journal_entries') {
      // Legacy local-only field that we never push and never get back.
      // Default to 1 so the row is treated as already-synced.
      out['synced'] = 1;
    }
    return out;
  }

  Object? _coerceFromRemote(dynamic v) {
    if (v == null) return null;
    if (v is num || v is String || v is bool) return v;
    return v.toString();
  }

  // ── Pending count for the status indicator ────────────────────────────

  Future<int> _countLocalPending() async {
    int total = 0;
    for (final t in _kSyncTables) {
      final cursor = await _entities.pushCursor(t);
      final cursorStr = cursor?.toUtc().toIso8601String();
      final rows = cursorStr == null
          ? await _ledger.db
              .rawQuery('SELECT COUNT(*) AS c FROM $t')
          : await _ledger.db.rawQuery(
              'SELECT COUNT(*) AS c FROM $t WHERE updated_at > ?',
              [cursorStr],
            );
      total += ((rows.first['c'] as num?) ?? 0).toInt();
    }
    return total;
  }

  void _emit(SyncStatus s) {
    _last = s;
    _statusCtrl.add(s);
  }
}
