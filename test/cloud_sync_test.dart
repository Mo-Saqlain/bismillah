// White-box tests for the v15 cloud-sync machinery.
//
// We do NOT hit a real Supabase instance here — that would make the
// suite flaky and depend on network. Instead the tests exercise the
// LOCAL side of the sync contract:
//
//   * Tenant ID is generated once and reused.
//   * The bump-on-update trigger sets `updated_at` on every row touch,
//     so the push cursor can find what changed.
//   * Push cursor + pull cursor are persisted via `EntityRepository`.
//   * Pull's "INSERT OR IGNORE" idempotency: simulating a re-pull of a
//     row that already exists locally must NOT overwrite the local
//     row's mutable fields (the "never destroy local writes" guarantee).
//   * Soft-deletes show up in the push window via the bump trigger.
//
// The network call itself (`client.from(t).upsert(rows)`) is a single
// line in SyncService and is tested manually against a live project.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/data/db/local_db.dart';
import 'package:bismillah_constructions/shared/data/repositories/entity_repository.dart';
import 'package:bismillah_constructions/shared/data/repositories/ledger_repository.dart';
import 'package:bismillah_constructions/shared/data/sync/sync_service.dart'
    show serverTimestampIsNewer;

late Database _db;
late EntityRepository _entityRepo;
late LedgerRepository _ledgerRepo;

Future<void> _resetDb() async {
  _db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 5,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  await LocalDb.instance.applySchemaForTests(_db);
  await _db.insert('app_settings',
      {'key': 'device_id', 'value': 'test-device-uuid'},
      conflictAlgorithm: ConflictAlgorithm.replace);
  _entityRepo = EntityRepository(_db);
  _ledgerRepo = LedgerRepository(_db);
}

void main() {
  setUpAll(() => sqfliteFfiInit());
  setUp(_resetDb);
  tearDown(() async => _db.close());

  group('Tenant id', () {
    test('ensureTenantId generates once and is stable thereafter', () async {
      final a = await _entityRepo.ensureTenantId();
      final b = await _entityRepo.ensureTenantId();
      expect(a, b, reason: 'second call returns the cached value');
      expect(a, hasLength(36), reason: 'looks like a UUID');
      expect(await _entityRepo.tenantIdOrNull(), a);
    });

    test('setTenantId overrides the generated value (second-device flow)',
        () async {
      await _entityRepo.ensureTenantId();
      const shared = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      await _entityRepo.setTenantId(shared);
      expect(await _entityRepo.tenantIdOrNull(), shared);
      // ensureTenantId now sees a non-empty value and returns it
      // verbatim instead of generating a fresh UUID.
      expect(await _entityRepo.ensureTenantId(), shared);
    });
  });

  group('Cloud sync enabled flag', () {
    test('defaults to true when never set', () async {
      expect(await _entityRepo.cloudSyncEnabled(), isTrue);
    });

    test('respects explicit on / off', () async {
      await _entityRepo.setCloudSyncEnabled(false);
      expect(await _entityRepo.cloudSyncEnabled(), isFalse);
      await _entityRepo.setCloudSyncEnabled(true);
      expect(await _entityRepo.cloudSyncEnabled(), isTrue);
    });
  });

  group('Push / pull cursors', () {
    test('cursors round-trip through app_settings per table', () async {
      final ts = DateTime.utc(2026, 5, 25, 14, 30);
      await _entityRepo.setPushCursor('journal_entries', ts);
      await _entityRepo.setPullCursor('projects', ts);
      expect(await _entityRepo.pushCursor('journal_entries'), ts);
      expect(await _entityRepo.pullCursor('projects'), ts);
      expect(await _entityRepo.pushCursor('projects'), isNull,
          reason: 'cursor is per-table');
    });
  });

  group('updated_at bump trigger', () {
    test('UPDATE bumps updated_at on every write', () async {
      final pId = (await _entityRepo.createProject(
              name: 'Site A', model: ProjectModel.withMaterial))
          .id;
      final beforeRows = await _db
          .query('projects', where: 'id = ?', whereArgs: [pId]);
      final beforeTs = beforeRows.first['updated_at'] as String;

      // Ensure the clock tick is visible.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _entityRepo.updateProjectFields(pId, name: 'Site A renamed');

      final afterRows = await _db
          .query('projects', where: 'id = ?', whereArgs: [pId]);
      final afterTs = afterRows.first['updated_at'] as String;

      expect(afterTs.compareTo(beforeTs), greaterThan(0),
          reason: 'trigger must advance updated_at on UPDATE');
    });

    test('Soft-delete shows up in the next push window', () async {
      final sId = (await _entityRepo.createSupplier(name: 'Steelco')).id;
      final pId = (await _entityRepo.createProject(
              name: 'Site A',
              model: ProjectModel.withMaterial,
              budget: 100000))
          .id;
      await _ledgerRepo.postMaterialBuy(
          amount: 10000, projectId: pId, supplierId: sId);

      // Take a "just-pushed" snapshot: cursor = max(updated_at) right now.
      final maxRows = await _db.rawQuery(
          'SELECT MAX(updated_at) AS m FROM journal_entries');
      final cursor = DateTime.parse(maxRows.first['m'] as String);
      await _entityRepo.setPushCursor('journal_entries', cursor);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Find one row of the pair and soft-delete the txn.
      final txnIdRow = await _db.query('journal_entries',
          where: 'project_id = ?', whereArgs: [pId], limit: 1);
      final txnId = txnIdRow.first['transaction_id'] as String;
      await _ledgerRepo.softDeleteTransaction(txnId, note: 'mistake');

      // Anything strictly newer than the cursor is what would be pushed
      // next. Both legs of the soft-deleted txn must be in there.
      final newer = await _db.query(
        'journal_entries',
        where: 'updated_at > ?',
        whereArgs: [cursor.toUtc().toIso8601String()],
      );
      expect(newer, hasLength(2),
          reason: 'soft-delete must bump updated_at on both legs');
      for (final r in newer) {
        expect(r['is_deleted'], 1);
      }
    });
  });

  group('Pull reconciliation — last-write-wins', () {
    test('serverTimestampIsNewer compares by instant across timestamp formats',
        () {
      // Server rows use +00:00 + microseconds; local rows use Z + millis.
      expect(
          serverTimestampIsNewer('2026-07-09T13:38:15.000000+00:00',
              '2026-07-09T13:38:14.999Z'),
          isTrue);
      expect(
          serverTimestampIsNewer('2026-07-09T13:38:14.000000+00:00',
              '2026-07-09T13:38:15.000Z'),
          isFalse);
      // Equal instant is NOT strictly newer → local wins.
      expect(
          serverTimestampIsNewer('2026-07-09T13:38:14.500000+00:00',
              '2026-07-09T13:38:14.500Z'),
          isFalse);
      // Null handling: no local → server wins; no server → server loses.
      expect(serverTimestampIsNewer('2026-07-09T13:38:14.500Z', null), isTrue);
      expect(serverTimestampIsNewer(null, '2026-07-09T13:38:14.500Z'), isFalse);
    });

    test('a NEWER server row overwrites the local copy', () async {
      final pId = (await _entityRepo.createProject(
              name: 'Site A',
              model: ProjectModel.withMaterial,
              budget: 100000))
          .id;
      final local =
          (await _db.query('projects', where: 'id = ?', whereArgs: [pId]))
              .first;
      final localTs = local['updated_at'] as String;
      // A pulled row that is strictly newer, with a different name.
      final incoming = Map<String, Object?>.from(local)
        ..['name'] = 'From cloud (newer)'
        ..['updated_at'] = DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 5))
            .toIso8601String();
      // Apply exactly as _pullTable does.
      if (serverTimestampIsNewer(incoming['updated_at'] as String?, localTs)) {
        await _db.update('projects', incoming,
            where: 'id = ?', whereArgs: [pId]);
      }
      final after = await _entityRepo.project(pId);
      expect(after!.name, 'From cloud (newer)');
    });

    test('an OLDER server row does NOT overwrite a newer local edit',
        () async {
      final pId = (await _entityRepo.createProject(
              name: 'Site A',
              model: ProjectModel.withMaterial,
              budget: 100000))
          .id;
      // Local edit bumps updated_at to "now".
      await _entityRepo.updateProjectFields(pId, name: 'Locally renamed');
      final local =
          (await _db.query('projects', where: 'id = ?', whereArgs: [pId]))
              .first;
      final localTs = local['updated_at'] as String;
      // A stale pulled row (older timestamp) tries to overwrite.
      final incoming = Map<String, Object?>.from(local)
        ..['name'] = 'Stale cloud name'
        ..['updated_at'] = DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 1))
            .toIso8601String();
      if (serverTimestampIsNewer(incoming['updated_at'] as String?, localTs)) {
        await _db.update('projects', incoming,
            where: 'id = ?', whereArgs: [pId]);
      }
      final after = await _entityRepo.project(pId);
      expect(after!.name, 'Locally renamed',
          reason: 'a stale server row must not clobber a newer local edit');
    });

  });

  group('Orphan retry buffer (v20)', () {
    test('resetPushCursors clears push cursors but leaves pull cursors',
        () async {
      final ts = DateTime.utc(2026, 5, 25);
      await _entityRepo.setPushCursor('projects', ts);
      await _entityRepo.setPushCursor('journal_entries', ts);
      await _entityRepo.setPullCursor('projects', ts);
      await _entityRepo.resetPushCursors();
      expect(await _entityRepo.pushCursor('projects'), isNull);
      expect(await _entityRepo.pushCursor('journal_entries'), isNull);
      expect(await _entityRepo.pullCursor('projects'), ts,
          reason: 'pull cursors are untouched by a push reset');
    });

    test('a child pulled before its parent fails, then heals once the parent '
        'arrives (self-healing pull contract)', () async {
      const childId = 'mi-orphan-1';
      final now = DateTime.now().toUtc().toIso8601String();
      final child = <String, Object?>{
        'id': childId,
        'project_id': 'missing-project',
        'supplier_id': null,
        'material_type': 'Cement',
        'unit': 'lump',
        'total_cost': 29500.0,
        'txn_type': 'purchase',
        'is_deleted': 0,
        'created_at': now,
        'updated_at': now,
      };

      // 1. Parent absent → the FK insert fails with SQLITE_CONSTRAINT_FOREIGNKEY.
      DatabaseException? caught;
      try {
        await _db.insert('material_inventory', child);
      } on DatabaseException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull, reason: 'orphan child must not insert');
      expect(caught!.getResultCode(), 787, reason: 'is an FK violation');

      // 2. Buffer it (what _bufferOrphans does).
      await _db.insert('pending_pull', {
        'id': childId,
        'table_name': 'material_inventory',
        'payload': jsonEncode(child),
        'attempts': 0,
        'first_seen': now,
      });
      expect(
          await _db.query('pending_pull',
              where: 'id = ?', whereArgs: [childId]),
          hasLength(1));

      // 3. The parent finally arrives (a later pull / a re-push from its owner).
      await _db.insert('projects', {
        'id': 'missing-project',
        'name': 'Late Project',
        'model': ProjectModel.withMaterial.db,
        'status': ProjectStatus.active.db,
        'completion_percent': 0,
        'is_archived': 0,
        'created_at': now,
        'updated_at': now,
      });

      // 4. Flush retries the buffered payload — now it inserts and clears.
      final payload = (jsonDecode((await _db.query('pending_pull',
                  where: 'id = ?', whereArgs: [childId]))
              .first['payload'] as String) as Map)
          .cast<String, Object?>();
      await _db.insert('material_inventory', payload,
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _db.delete('pending_pull',
          where: 'id = ?', whereArgs: [childId]);

      expect(
          await _db.query('material_inventory',
              where: 'id = ?', whereArgs: [childId]),
          hasLength(1),
          reason: 'child heals once its parent exists');
      expect(await _db.query('pending_pull'), isEmpty,
          reason: 'buffer is cleared after a successful retry');
    });

    test('A row with a brand-new id from the cloud lands successfully',
        () async {
      // Pretend this row exists on phone-2 only and is being pulled.
      const newId = 'remote-project-1';
      await _db.insert(
        'projects',
        {
          'id': newId,
          'name': 'From other device',
          'model': ProjectModel.withMaterial.db,
          'status': ProjectStatus.active.db,
          'completion_percent': 0,
          'is_archived': 0,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      final pulled = await _entityRepo.project(newId);
      expect(pulled, isNotNull);
      expect(pulled!.name, 'From other device');
    });
  });
}
