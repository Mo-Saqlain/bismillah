import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
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
    if (!force && !await _entities.cloudSyncEnabled()) {
      _emit(SyncStatus(
        state: SyncState.disabled,
        pending: 0,
        lastSyncAt: _last.lastSyncAt,
        message: 'Cloud sync disabled in Settings.',
      ));
      return;
    }
    if (_syncing) return;

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
    } catch (e) {
      _emit(SyncStatus(
        state: SyncState.error,
        pending: pending,
        message: e.toString(),
        lastSyncAt: _last.lastSyncAt,
      ));
    } finally {
      _syncing = false;
    }
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
      await db.transaction((txn) async {
        for (final r in rows) {
          final local = _fromRemote(r, table);
          // INSERT OR IGNORE — if the id exists locally, the remote row
          // is dropped. This is the "never overwrite local writes"
          // guarantee. Soft-deletes propagate too: a row with
          // is_deleted=1 from the cloud only lands if it didn't already
          // exist locally; if it did, the local copy decides whether
          // it's deleted.
          await txn.insert(
            table,
            local,
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      });

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

  /// Local row → Supabase payload. Adds tenant_id, drops the
  /// SQLite-only `synced` column (legacy from the v1 push design),
  /// leaves `updated_at` as-is so Postgres preserves the local
  /// monotonic ordering on first push (subsequent updates get a fresh
  /// server-side timestamp via the bump trigger).
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
