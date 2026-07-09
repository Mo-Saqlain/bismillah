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
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bismillah_constructions/core/constants.dart';
import 'package:bismillah_constructions/data/db/local_db.dart';
import 'package:bismillah_constructions/data/repositories/entity_repository.dart';
import 'package:bismillah_constructions/data/repositories/ledger_repository.dart';

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

  group('Pull idempotency (INSERT OR IGNORE)', () {
    test('Re-inserting a row with an existing id leaves the local copy '
        'untouched (the "never destroy local writes" guarantee)',
        () async {
      // Local writes the row first.
      final pId = (await _entityRepo.createProject(
              name: 'Site A',
              model: ProjectModel.withMaterial,
              budget: 100000))
          .id;
      // Local renames it after — this is the "device's own write" we
      // must never lose.
      await _entityRepo.updateProjectFields(pId, name: 'Locally renamed');

      // Pull comes in with the original name (simulating the cloud copy
      // before the local rename) — same id, different `name`.
      final pullPayload = <String, Object?>{
        'id': pId,
        'name': 'Original from cloud',
        'model': ProjectModel.withMaterial.db,
        'status': ProjectStatus.active.db,
        'completion_percent': 0,
        'is_archived': 0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      // SyncService uses ConflictAlgorithm.ignore — identical semantics.
      await _db.insert(
        'projects',
        pullPayload,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      final after = await _entityRepo.project(pId);
      expect(after!.name, 'Locally renamed',
          reason: 'pulled row must NOT overwrite the local copy');
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
