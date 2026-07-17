import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/error_reporter.dart';
import '../repositories/entity_repository.dart';
import '../repositories/ledger_repository.dart';

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

  StreamSubscription? _connSub;
  Timer? _ticker;
  bool _syncing = false;

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
    _ticker = Timer.periodic(const Duration(minutes: 2), (_) => syncNow());
    unawaited(syncNow());
  }

  void dispose() {
    _connSub?.cancel();
    _ticker?.cancel();
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
  Future<void> syncNow({bool force = false}) async {
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

        for (final table in _kSyncTables) {
          await _pushTable(client, table, tenantId);
        }
        for (final table in _kSyncTables) {
          await _pullTable(client, table, tenantId);
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
      final payload = slice.map((r) => _toRemote(r, table, tenantId)).toList();
      await client.from(table).upsert(payload);
      for (final r in slice) {
        final u = r['updated_at'] as String?;
        if (u != null && (maxSeen == null || u.compareTo(maxSeen) > 0)) {
          maxSeen = u;
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

      final db = _ledger.db;
      final orphanIds = <Object?>[];
      await db.transaction((txn) async {
        for (final r in rows) {
          final local = _fromRemote(r, table);
          // Last-write-wins: Supabase is the source of truth for the latest
          // edit. A brand-new id inserts; an existing id is overwritten only
          // when the server row's `updated_at` is strictly newer than the
          // local one (so a genuine local edit made offline isn't clobbered
          // by a stale server copy). Edits and soft-deletes therefore
          // propagate across devices, while everything stays offline-capable.
          //
          // Safe against ping-pong: migration 0005 drops the server-side
          // auto-bump trigger, so re-pushing a just-pulled row is a no-op
          // upsert that doesn't change its timestamp.
          final id = local['id'];
          // Tenant fragmentation can leave a child row (e.g. material_inventory)
          // tagged with this tenant while its parent project/supplier sits
          // under a different tenant and is filtered out of the pull — so the
          // parent never lands locally and the child's FK fails. Skip just that
          // row instead of aborting the whole page (and the whole re-pull).
          // A caught constraint error rolls back only its own statement, so the
          // transaction stays live and the remaining rows still commit.
          try {
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
          } catch (e) {
            if (_isForeignKeyError(e)) {
              orphanIds.add(id);
            } else {
              rethrow;
            }
          }
        }
      });

      if (orphanIds.isNotEmpty) {
        ErrorReporter.report(
          'Skipped ${orphanIds.length} orphaned $table row(s) during pull — '
          'their parent project/supplier is under a different tenant and was '
          'not synced. Unify the tenant_id on the server, then re-pull. '
          'ids: ${orphanIds.join(', ')}',
          source: 'Sync',
        );
      }

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
