// Black-box tests for the backup, restore and DB-persistence subsystem —
// the user's primary concern.
//
// "Black-box" here means: we exercise the public surface (BackupService,
// DB open/close, file mechanics) and assert on observable outcomes
// (file presence, file contents, query results) without peeking at
// implementation details. Where a code path needs platform-channel APIs
// (path_provider) we test the *equivalent file mechanics* on a real temp
// directory instead, since the question we are answering — "does my
// backup actually preserve data through reopen / corruption / crash" —
// is really a SQLite + filesystem question.
//
// All tests use a real on-disk SQLite file via `sqflite_common_ffi`, so
// open / close / copy / reopen behaviours match production.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bismillah_constructions/core/constants.dart';
import 'package:bismillah_constructions/data/db/local_db.dart';
import 'package:bismillah_constructions/data/repositories/entity_repository.dart';
import 'package:bismillah_constructions/data/repositories/ledger_repository.dart';
import 'package:bismillah_constructions/data/services/backup_service.dart';

// ── Test helpers ────────────────────────────────────────────────────────

late Directory _tmp;

Future<Database> _openOnDiskDb(String path) async {
  // Schema is applied only on first creation (sqflite drives onCreate
  // when the stored user_version is 0). Subsequent opens of the same
  // path skip onCreate, which is exactly the behaviour we want when
  // simulating "reopen after close" or "open the restored backup".
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 11,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        await LocalDb.instance.applySchemaForTests(db);
        await db.insert(
          'app_settings',
          {'key': 'device_id', 'value': 'test-device-uuid'},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      },
    ),
  );
}

/// Mirrors [BackupService._atomicCopy] so we can verify the contract from
/// outside the class. The real method is private; this is the public
/// equivalent used both as the SUT and as a test fixture.
Future<void> _atomicCopy(String src, String dest) async {
  final tmp = File('$dest.tmp');
  if (await tmp.exists()) await tmp.delete();
  await File(src).copy(tmp.path);
  await tmp.rename(dest);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    _tmp = await Directory.systemTemp.createTemp('bismillah_bb_');
  });

  tearDown(() async {
    if (await _tmp.exists()) {
      await _tmp.delete(recursive: true);
    }
  });

  // ─────────────────────────────────────────────────────────────────────
  //  validateBackupFile — defends against bad imports
  // ─────────────────────────────────────────────────────────────────────

  group('BackupService.validateBackupFile', () {
    late BackupService svc;
    late Database stubDb;

    setUp(() async {
      // validateBackupFile only does file-level checks — schema isn't
      // touched, so we just need *a* Database object. Open a bare
      // in-memory DB (no version, no schema) so cleanup is trivial.
      stubDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      svc = BackupService(EntityRepository(stubDb));
    });

    tearDown(() async => stubDb.close());

    test('Rejects: file does not exist', () async {
      final missing = p.join(_tmp.path, 'nope.db');
      expect(await svc.validateBackupFile(missing), contains('does not exist'));
    });

    test('Rejects: file is too small', () async {
      final f = File(p.join(_tmp.path, 'tiny.db'));
      await f.writeAsBytes(Uint8List.fromList([0x42, 0x43, 0x44]));
      expect(await svc.validateBackupFile(f.path), contains('too small'));
    });

    test('Rejects: file has wrong magic header', () async {
      final f = File(p.join(_tmp.path, 'fake.db'));
      // 200 bytes of garbage — bigger than the 100B threshold but not a
      // valid SQLite file.
      await f.writeAsBytes(Uint8List(200));
      expect(await svc.validateBackupFile(f.path),
          contains('Not a SQLite database'));
    });

    test('Accepts: a real SQLite database file', () async {
      // Build a real SQLite file via the same factory production uses.
      final dbPath = p.join(_tmp.path, 'real.db');
      final db = await _openOnDiskDb(dbPath);
      await db.close();

      expect(await svc.validateBackupFile(dbPath), isNull,
          reason: 'a real .db produced by the same engine must validate');
    });

    test('Rejects: text file disguised with .db extension', () async {
      final f = File(p.join(_tmp.path, 'fake.db'));
      await f.writeAsString('This is just a text file. ' * 20);
      expect(await svc.validateBackupFile(f.path),
          contains('Not a SQLite database'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Atomic copy semantics — crash-safety contract
  // ─────────────────────────────────────────────────────────────────────

  group('Atomic copy', () {
    test('Successful copy: dest exists, .tmp is gone', () async {
      final src = File(p.join(_tmp.path, 'src.db'));
      await src.writeAsString('hello');
      final dest = p.join(_tmp.path, 'dest.db');

      await _atomicCopy(src.path, dest);

      expect(File(dest).existsSync(), true);
      expect(File('$dest.tmp').existsSync(), false,
          reason: '.tmp must be renamed away after success');
      expect(await File(dest).readAsString(), 'hello');
    });

    test('Stale .tmp from a previous crash is cleared before re-copy',
        () async {
      final src = File(p.join(_tmp.path, 'src.db'));
      await src.writeAsString('NEW');
      final dest = p.join(_tmp.path, 'dest.db');
      // Simulate a crashed previous run: leave a partial .tmp behind.
      await File('$dest.tmp').writeAsString('PARTIAL_FROM_CRASHED_RUN');

      await _atomicCopy(src.path, dest);

      expect(await File(dest).readAsString(), 'NEW',
          reason: 'fresh copy must overwrite stale .tmp content');
      expect(File('$dest.tmp').existsSync(), false);
    });

    test('Overwrites existing dest file in place', () async {
      final src = File(p.join(_tmp.path, 'src.db'));
      await src.writeAsString('NEW');
      final dest = File(p.join(_tmp.path, 'dest.db'));
      await dest.writeAsString('OLD');

      await _atomicCopy(src.path, dest.path);

      expect(await dest.readAsString(), 'NEW');
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Backup → Restore round-trip via real on-disk SQLite files.
  //  These mirror what BackupService.runBackup → importBackup do
  //  end-to-end, but using temp files so we can run in a unit test.
  // ─────────────────────────────────────────────────────────────────────

  group('Backup → Restore round-trip', () {
    test('Data written before backup is fully recovered after restore',
        () async {
      // 1. Build a "live" DB with data.
      final livePath = p.join(_tmp.path, 'live.db');
      var live = await _openOnDiskDb(livePath);
      var entityRepo = EntityRepository(live);
      var ledgerRepo = LedgerRepository(live);

      final supplier =
          await entityRepo.createSupplier(name: 'Round-Trip Vendor');
      final project = await entityRepo.createProject(
          name: 'Round-Trip Site',
          model: ProjectModel.withMaterial,
          budget: 500000,
        );
      await ledgerRepo.postReceiveFromProject(
          amount: 200000, projectId: project.id, receivedInto: Accounts.cash);
      await ledgerRepo.postMaterialBuy(
          amount: 75000, projectId: project.id, supplierId: supplier.id);

      // 2. Take a backup (atomic copy to a sibling file).
      await live.close();
      final backupPath = p.join(_tmp.path, 'backup.db');
      await _atomicCopy(livePath, backupPath);

      // 3. SIMULATE A FRESH INSTALL — point at a brand-new "live" path
      //    and copy the backup over it.
      final newLivePath = p.join(_tmp.path, 'restored.db');
      await _atomicCopy(backupPath, newLivePath);

      // 4. Open the restored DB and verify every datum survived.
      final restored = await _openOnDiskDb(newLivePath);
      final restoredEntities = EntityRepository(restored);
      final restoredLedger = LedgerRepository(restored);

      final suppliers = await restoredEntities.suppliers();
      expect(suppliers.length, 1);
      expect(suppliers.first.name, 'Round-Trip Vendor');

      final projects = await restoredEntities.projects();
      expect(projects.length, 1);
      expect(projects.first.name, 'Round-Trip Site');
      expect(projects.first.budget, 500000);

      final cashBal = await restoredLedger.accountBalance(Accounts.cash.id);
      expect(cashBal, 200000,
          reason: 'cash position must survive backup/restore');

      final mat =
          await restoredLedger.accountBalance(Accounts.materialCosts.id);
      expect(mat, 75000);

      final payable =
          await restoredLedger.creditBalance(Accounts.supplierPayables.id);
      expect(payable, 75000,
          reason: 'supplier payable must survive backup/restore');

      await restored.close();
    });

    test('Soft-deleted transactions stay soft-deleted across backup/restore',
        () async {
      final livePath = p.join(_tmp.path, 'live.db');
      var live = await _openOnDiskDb(livePath);
      final ledger = LedgerRepository(live);
      final entity = EntityRepository(live);

      final p1 = await entity.createProject(name: 'X', model: ProjectModel.withMaterial);
      final txn = await ledger.postReceiveFromProject(
          amount: 1000, projectId: p1.id, receivedInto: Accounts.cash);
      await ledger.softDeleteTransaction(txn);

      await live.close();
      final dest = p.join(_tmp.path, 'restored.db');
      await _atomicCopy(livePath, dest);

      final restored = await _openOnDiskDb(dest);
      final restoredLedger = LedgerRepository(restored);
      final rev =
          await restoredLedger.creditBalance(Accounts.projectRevenue.id);
      expect(rev, 0,
          reason: 'soft-deleted txn must NOT reappear after restore');

      // The journal rows should still be there (preserved for audit).
      final rows = await restored.query('journal_entries',
          where: 'transaction_id = ?', whereArgs: [txn]);
      expect(rows.length, 2);
      expect(rows.first['is_deleted'], 1);

      await restored.close();
    });

    test('Foreign key constraints survive restore', () async {
      final livePath = p.join(_tmp.path, 'live.db');
      var live = await _openOnDiskDb(livePath);
      final entity = EntityRepository(live);
      final ledger = LedgerRepository(live);

      final s = await entity.createSupplier(name: 'FK Vendor');
      final pr = await entity.createProject(name: 'FK Site', model: ProjectModel.withMaterial);
      await ledger.postMaterialBuy(
          amount: 100, projectId: pr.id, supplierId: s.id);

      await live.close();
      final dest = p.join(_tmp.path, 'restored.db');
      await _atomicCopy(livePath, dest);

      final restored = await _openOnDiskDb(dest);
      // Try to insert a journal_entry row referencing a non-existent
      // project_id — FK should reject it.
      Object? err;
      try {
        await restored.insert('journal_entries', {
          'id': 'orphan',
          'transaction_id': 'orphan-tx',
          'account_id': Accounts.materialCosts.id,
          'project_id': 'project-that-does-not-exist',
          'debit': 1,
          'credit': 0,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'is_deleted': 0,
          'synced': 0,
        });
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull,
          reason: 'FK constraint must survive backup/restore');
      expect(err.toString(), contains('FOREIGN KEY'));

      await restored.close();
    });

    test('Schema version persists — a v11 backup opens as v11', () async {
      final livePath = p.join(_tmp.path, 'live.db');
      final live = await _openOnDiskDb(livePath);
      await live.close();

      final dest = p.join(_tmp.path, 'restored.db');
      await _atomicCopy(livePath, dest);

      // Open WITHOUT applying schema — just check the recorded version.
      final raw = await databaseFactoryFfi.openDatabase(dest);
      final ver = await raw.getVersion();
      expect(ver, 11,
          reason: 'restored DB must report the schema version it was '
              'taken at, otherwise sqflite would re-run onCreate');
      await raw.close();
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Persistence: data survives close / reopen
  // ─────────────────────────────────────────────────────────────────────

  group('DB persistence', () {
    test('Every data point survives close + reopen at the same path',
        () async {
      final dbPath = p.join(_tmp.path, 'persist.db');

      // ── Session 1: write everything ─────────────────────────────────
      var db = await _openOnDiskDb(dbPath);
      var entity = EntityRepository(db);
      var ledger = LedgerRepository(db);

      final bank = await entity.createBank(name: 'Test Bank');
      final supplier = await entity.createSupplier(name: 'Vendor');
      final pr = await entity.createProject(
          name: 'Persist Site',
          model: ProjectModel.withMaterial,
          budget: 1000000);

      await ledger.postReceiveFromProject(
          amount: 500000,
          projectId: pr.id,
          receivedInto: Account(bank.id, bank.name, AccountType.asset));
      await ledger.postMaterialBuy(
          amount: 200000, projectId: pr.id, supplierId: supplier.id);
      await ledger.postLabourCredit(
          amount: 50000, projectId: pr.id, supplierId: supplier.id);

      await db.close();

      // ── Session 2: reopen and verify ─────────────────────────────────
      db = await _openOnDiskDb(dbPath);
      entity = EntityRepository(db);
      ledger = LedgerRepository(db);

      expect((await entity.banks()).first.name, 'Test Bank');
      expect((await entity.suppliers()).first.name, 'Vendor');
      expect((await entity.projects()).first.budget, 1000000);

      final bankBal = await ledger.accountBalance(bank.id);
      expect(bankBal, 500000);

      final mat = await ledger.accountBalance(Accounts.materialCosts.id);
      expect(mat, 200000);

      final lab = await ledger.accountBalance(Accounts.labourCosts.id);
      expect(lab, 50000);

      final payable =
          await ledger.creditBalance(Accounts.supplierPayables.id);
      expect(payable, 250000, reason: '200K material + 50K labour credit');

      await db.close();
    });

    test('100 transactions written in one session all readable in next',
        () async {
      final dbPath = p.join(_tmp.path, 'bulk.db');
      var db = await _openOnDiskDb(dbPath);
      var entity = EntityRepository(db);
      var ledger = LedgerRepository(db);

      final s = await entity.createSupplier(name: 'Bulk');
      final pr = await entity.createProject(name: 'Bulk Site', model: ProjectModel.withMaterial);

      for (var i = 0; i < 100; i++) {
        await ledger.postMaterialBuy(
            amount: 10, projectId: pr.id, supplierId: s.id);
      }
      await db.close();

      db = await _openOnDiskDb(dbPath);
      ledger = LedgerRepository(db);
      final rows = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM journal_entries WHERE is_deleted = 0');
      expect(rows.first['c'], 200,
          reason: '100 txns × 2 rows each = 200 entries');
      final mat = await ledger.accountBalance(Accounts.materialCosts.id);
      expect(mat, 1000);

      await db.close();
    });

    test('Reopening the same path twice yields the same data', () async {
      final dbPath = p.join(_tmp.path, 'idempotent.db');
      var db = await _openOnDiskDb(dbPath);
      final entity = EntityRepository(db);
      await entity.createProject(name: 'Site', model: ProjectModel.withMaterial);
      await db.close();

      // First reopen.
      db = await _openOnDiskDb(dbPath);
      expect((await EntityRepository(db).projects()).length, 1);
      await db.close();

      // Second reopen — should still show the same single project.
      db = await _openOnDiskDb(dbPath);
      expect((await EntityRepository(db).projects()).length, 1);
      await db.close();
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Rollback semantics — `.before_import` snapshot recovery
  // ─────────────────────────────────────────────────────────────────────

  group('Import rollback (.before_import)', () {
    test('Importing creates a .before_import snapshot containing pre-import data',
        () async {
      // Build pre-import live DB.
      final livePath = p.join(_tmp.path, 'live.db');
      var live = await _openOnDiskDb(livePath);
      await EntityRepository(live).createProject(name: 'Pre-Import Site', model: ProjectModel.withMaterial);
      await live.close();

      // Build a "backup" with different data to import.
      final backupPath = p.join(_tmp.path, 'backup.db');
      var backup = await _openOnDiskDb(backupPath);
      await EntityRepository(backup).createProject(name: 'Backup Site', model: ProjectModel.withMaterial);
      await backup.close();

      // ── Simulate importBackup mechanics ──────────────────────────────
      // 1. Snapshot current live to .before_import
      await File(livePath).copy('$livePath.before_import');
      // 2. Atomically replace live with backup
      await _atomicCopy(backupPath, livePath);

      // After: live has Backup Site, .before_import has Pre-Import Site.
      live = await _openOnDiskDb(livePath);
      expect((await EntityRepository(live).projects()).first.name,
          'Backup Site');
      await live.close();

      final snap = await _openOnDiskDb('$livePath.before_import');
      expect((await EntityRepository(snap).projects()).first.name,
          'Pre-Import Site',
          reason: 'rollback snapshot must capture data as it was BEFORE import');
      await snap.close();
    });

    test('Rollback restores pre-import state', () async {
      final livePath = p.join(_tmp.path, 'live.db');
      var live = await _openOnDiskDb(livePath);
      await EntityRepository(live).createProject(name: 'Original', model: ProjectModel.withMaterial);
      await live.close();

      // import: snapshot first, then overwrite
      await File(livePath).copy('$livePath.before_import');
      var backup = await _openOnDiskDb(p.join(_tmp.path, 'b.db'));
      await EntityRepository(backup).createProject(name: 'Imported', model: ProjectModel.withMaterial);
      await backup.close();
      await _atomicCopy(p.join(_tmp.path, 'b.db'), livePath);

      // rollback: copy snapshot back over live
      await File('$livePath.before_import').copy(livePath);

      live = await _openOnDiskDb(livePath);
      final ps = await EntityRepository(live).projects();
      expect(ps.length, 1);
      expect(ps.first.name, 'Original',
          reason: 'rollback must restore the original project');
      await live.close();
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Corruption handling — what if the backup file is bad
  // ─────────────────────────────────────────────────────────────────────

  group('Corruption handling', () {
    late BackupService svc;
    late Database stubDb;

    setUp(() async {
      stubDb = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      svc = BackupService(EntityRepository(stubDb));
    });

    tearDown(() async => stubDb.close());

    test('Truncated .db file fails validation cleanly (no crash)', () async {
      // Build a real DB then truncate to ~50 bytes.
      final realPath = p.join(_tmp.path, 'real.db');
      final real = await _openOnDiskDb(realPath);
      await real.close();
      final truncatedPath = p.join(_tmp.path, 'truncated.db');
      final bytes = await File(realPath).readAsBytes();
      await File(truncatedPath).writeAsBytes(bytes.sublist(0, 50));

      final reason = await svc.validateBackupFile(truncatedPath);
      expect(reason, isNotNull);
      expect(reason, contains('too small'));
    });

    test('File with corrupted header but right size is rejected', () async {
      // 4 KB of garbage that's not a SQLite header.
      final path = p.join(_tmp.path, 'corrupt.db');
      final bytes = Uint8List(4096);
      bytes.fillRange(0, bytes.length, 0xAB);
      await File(path).writeAsBytes(bytes);

      final reason = await svc.validateBackupFile(path);
      expect(reason, contains('Not a SQLite database'));
    });
  });
}
