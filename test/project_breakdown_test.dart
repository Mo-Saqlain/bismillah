// Tests for the project-ledger trial-balance breakdown helpers added in
// this session: `projectSupplierBreakdown` and `projectMaterialBreakdown`.
// Both feed the Project Ledger's "By supplier" and "By material type"
// cards, so the math has to be correct or the user gets misleading
// summaries on top of an otherwise-correct ledger.
//
// These hit the real SQLite engine via sqflite_common_ffi — no mocks.
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

Future<String> _supplier(String name) async =>
    (await _entityRepo.createSupplier(name: name)).id;

Future<String> _project(String name, {double? budget}) async =>
    (await _entityRepo.createProject(
      name: name,
      model: ProjectModel.withMaterial,
      budget: budget,
    ))
        .id;

void main() {
  setUpAll(() => sqfliteFfiInit());
  setUp(_resetDb);
  tearDown(() async => _db.close());

  group('projectSupplierBreakdown', () {
    test('aggregates material + labour debits per supplier', () async {
      final pId = await _project('Site A', budget: 1000000);

      final steelco = await _supplier('Steelco');
      final cementCo = await _supplier('CementCo');
      final mason = await _supplier('Mason team');

      // Steelco: two material credits (100 + 150 = 250).
      await _ledgerRepo.postMaterialBuy(
          amount: 100000, projectId: pId, supplierId: steelco);
      await _ledgerRepo.postMaterialBuy(
          amount: 150000, projectId: pId, supplierId: steelco);

      // CementCo: one material credit (80).
      await _ledgerRepo.postMaterialBuy(
          amount: 80000, projectId: pId, supplierId: cementCo);

      // Mason team: labour-cost debit (50).
      await _ledgerRepo.postLabourPayment(
          amount: 50000,
          projectId: pId,
          supplierId: mason,
          paidFrom: Accounts.cash);

      final rows = await _ledgerRepo.projectSupplierBreakdown(pId);
      expect(rows, hasLength(3));
      // Sorted highest-spend-first.
      expect(rows[0].supplierId, steelco);
      expect(rows[0].total, closeTo(250000, 0.01));
      expect(rows[1].supplierId, cementCo);
      expect(rows[1].total, closeTo(80000, 0.01));
      expect(rows[2].supplierId, mason);
      expect(rows[2].total, closeTo(50000, 0.01));
    });

    test('counter-purchase rows surface under an empty supplier id', () async {
      final pId = await _project('Site A', budget: 500000);
      await _ledgerRepo.postMaterialCounter(
        amount: 7500,
        projectId: pId,
        paidFrom: Accounts.cash,
      );

      final rows = await _ledgerRepo.projectSupplierBreakdown(pId);
      expect(rows, hasLength(1));
      expect(rows.first.supplierId, '',
          reason: 'counter purchases have no supplier — empty string bucket');
      expect(rows.first.total, closeTo(7500, 0.01));
    });

    test('excludes other projects + soft-deleted rows', () async {
      final p1 = await _project('Site A', budget: 1000000);
      final p2 = await _project('Site B', budget: 1000000);
      final steelco = await _supplier('Steelco');

      await _ledgerRepo.postMaterialBuy(
          amount: 100000, projectId: p1, supplierId: steelco);
      await _ledgerRepo.postMaterialBuy(
          amount: 200000, projectId: p2, supplierId: steelco);

      // Soft-delete the p1 buy.
      final p1Txn = (await _db.query('journal_entries',
              where: 'project_id = ?', whereArgs: [p1], limit: 1))
          .first['transaction_id'] as String;
      await _ledgerRepo.softDeleteTransaction(p1Txn, note: 'mistake');

      final rows = await _ledgerRepo.projectSupplierBreakdown(p1);
      expect(rows, isEmpty,
          reason: 'soft-deleted rows must drop out of the breakdown');

      final rowsP2 = await _ledgerRepo.projectSupplierBreakdown(p2);
      expect(rowsP2, hasLength(1));
      expect(rowsP2.first.total, closeTo(200000, 0.01));
    });
  });

  group('projectMaterialBreakdown', () {
    test('aggregates total_cost per material_type from material_inventory',
        () async {
      final pId = await _project('Site A', budget: 1000000);
      final steelco = await _supplier('Steelco');

      // Two Cement buys against Steelco (100 + 50 = 150) plus one Sand
      // counter-purchase (12). The journal posts are done separately
      // because the production form-screen does the same: post the
      // ledger txn, then log the matching material_inventory row.
      final t1 = await _ledgerRepo.postMaterialBuy(
          amount: 100000, projectId: pId, supplierId: steelco);
      await _entityRepo.logMaterialPurchase(
        projectId: pId,
        supplierId: steelco,
        transactionId: t1,
        materialType: 'Cement',
        price: 100000,
        quantity: 200,
      );
      final t2 = await _ledgerRepo.postMaterialBuy(
          amount: 50000, projectId: pId, supplierId: steelco);
      await _entityRepo.logMaterialPurchase(
        projectId: pId,
        supplierId: steelco,
        transactionId: t2,
        materialType: 'Cement',
        price: 50000,
        quantity: 100,
      );
      final t3 = await _ledgerRepo.postMaterialCounter(
        amount: 12000,
        projectId: pId,
        paidFrom: Accounts.cash,
      );
      await _entityRepo.logMaterialPurchase(
        projectId: pId,
        transactionId: t3,
        materialType: 'Sand',
        price: 12000,
        quantity: 10,
      );

      final rows = await _ledgerRepo.projectMaterialBreakdown(pId);
      expect(rows, hasLength(2));
      // Sorted highest-first → Cement should come first.
      expect(rows[0].materialType, 'Cement');
      expect(rows[0].total, closeTo(150000, 0.01));
      expect(rows[1].materialType, 'Sand');
      expect(rows[1].total, closeTo(12000, 0.01));
    });

    test('soft-deleting a material buy drops it from the breakdown',
        () async {
      final pId = await _project('Site A', budget: 1000000);
      final steelco = await _supplier('Steelco');

      final t1 = await _ledgerRepo.postMaterialBuy(
          amount: 100000, projectId: pId, supplierId: steelco);
      await _entityRepo.logMaterialPurchase(
        projectId: pId,
        supplierId: steelco,
        transactionId: t1,
        materialType: 'Cement',
        price: 100000,
        quantity: 200,
      );
      final t2 = await _ledgerRepo.postMaterialBuy(
          amount: 50000, projectId: pId, supplierId: steelco);
      await _entityRepo.logMaterialPurchase(
        projectId: pId,
        supplierId: steelco,
        transactionId: t2,
        materialType: 'Cement',
        price: 50000,
        quantity: 100,
      );

      // Soft-delete the 50k buy.
      await _ledgerRepo.softDeleteTransaction(t2, note: 'mistake');

      final rows = await _ledgerRepo.projectMaterialBreakdown(pId);
      expect(rows, hasLength(1));
      expect(rows.first.total, closeTo(100000, 0.01),
          reason: 'soft-delete must also drop the material_inventory row');
    });
  });
}
