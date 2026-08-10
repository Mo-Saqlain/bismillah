import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/data/db/local_db.dart';
import 'package:bismillah_constructions/shared/data/repositories/entity_repository.dart';
import 'package:bismillah_constructions/shared/data/repositories/ledger_repository.dart';

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
  _entityRepo = EntityRepository(_db);
  _ledgerRepo = LedgerRepository(_db);
}

void main() {
  setUpAll(() => sqfliteFfiInit());
  setUp(_resetDb);
  tearDown(() async => _db.close());

  group('Material Price Escalation calculations', () {
    test('calculates rate escalation claim from initial purchase baseline',
        () async {
      final project = await _entityRepo.createProject(
        name: 'Villa 101',
        model: ProjectModel.withMaterial,
        budget: 5000000,
        clientName: 'Ali Ahmed',
      );
      final supplier = await _entityRepo.createSupplier(name: 'Cement Co');

      // Purchase 1: 100 bags @ Rs 1,200 = 120,000 (Baseline)
      final txn1 = await _ledgerRepo.postMaterialBuy(
        amount: 120000,
        projectId: project.id,
        supplierId: supplier.id,
      );
      await _entityRepo.logMaterialPurchase(
        projectId: project.id,
        supplierId: supplier.id,
        transactionId: txn1,
        materialType: 'cement',
        price: 120000,
        quantity: 100,
      );

      // Purchase 2: 50 bags @ Rs 1,500 = 75,000 (+300 delta * 50 = 15,000 extra)
      final txn2 = await _ledgerRepo.postMaterialBuy(
        amount: 75000,
        projectId: project.id,
        supplierId: supplier.id,
      );
      await _entityRepo.logMaterialPurchase(
        projectId: project.id,
        supplierId: supplier.id,
        transactionId: txn2,
        materialType: 'cement',
        price: 75000,
        quantity: 50,
      );

      final summary =
          await _ledgerRepo.projectEscalationSummary(project.id);

      expect(summary.projectId, project.id);
      expect(summary.projectName, 'Villa 101');
      expect(summary.clientName, 'Ali Ahmed');
      expect(summary.items, hasLength(1));

      final cement = summary.items.first;
      expect(cement.materialType, 'cement');
      expect(cement.baselineRate, 1200.0);
      expect(cement.latestRate, 1500.0);
      expect(cement.maxRate, 1500.0);
      expect(cement.totalQuantity, 150.0);
      expect(cement.totalActualCost, 195000.0);
      expect(cement.totalBaselineCost, 180000.0); // 150 * 1200
      expect(cement.escalationClaim, 15000.0);
      expect(cement.percentageIncrease, 25.0); // (1500-1200)/1200 * 100
      expect(summary.totalEscalationClaim, 15000.0);
    });

    test('supports custom baseline rate override', () async {
      final project = await _entityRepo.createProject(
        name: 'Plaza 202',
        model: ProjectModel.withMaterial,
      );
      final supplier = await _entityRepo.createSupplier(name: 'Steel Corp');

      // Purchase 1: 2 tons @ Rs 240,000 = 480,000
      final txn1 = await _ledgerRepo.postMaterialBuy(
        amount: 480000,
        projectId: project.id,
        supplierId: supplier.id,
      );
      await _entityRepo.logMaterialPurchase(
        projectId: project.id,
        supplierId: supplier.id,
        transactionId: txn1,
        materialType: 'steel',
        price: 480000,
        quantity: 2,
      );

      // Purchase 2: 1 ton @ Rs 280,000 = 280,000
      final txn2 = await _ledgerRepo.postMaterialBuy(
        amount: 280000,
        projectId: project.id,
        supplierId: supplier.id,
      );
      await _entityRepo.logMaterialPurchase(
        projectId: project.id,
        supplierId: supplier.id,
        transactionId: txn2,
        materialType: 'steel',
        price: 280000,
        quantity: 1,
      );

      // Custom agreed baseline rate: Rs 200,000 / ton
      final summary = await _ledgerRepo.projectEscalationSummary(
        project.id,
        customBaselines: {'steel': 200000},
      );

      final steel = summary.items.first;
      expect(steel.baselineRate, 200000.0);
      // P1 extra: (240k - 200k) * 2 = 80,000
      // P2 extra: (280k - 200k) * 1 = 80,000
      // Total extra: 160,000
      expect(steel.escalationClaim, 160000.0);
      expect(summary.totalEscalationClaim, 160000.0);
    });

    test('excludes soft-deleted material purchases', () async {
      final project = await _entityRepo.createProject(
        name: 'House 303',
        model: ProjectModel.withMaterial,
      );
      final supplier = await _entityRepo.createSupplier(name: 'Brick Kiln');

      final buy1 = await _ledgerRepo.postMaterialBuy(
        amount: 50000,
        projectId: project.id,
        supplierId: supplier.id,
      );
      final mat1 = await _entityRepo.logMaterialPurchase(
        projectId: project.id,
        supplierId: supplier.id,
        transactionId: buy1,
        materialType: 'bricks',
        price: 50000,
        quantity: 5,
      );

      final buy2 = await _ledgerRepo.postMaterialBuy(
        amount: 70000,
        projectId: project.id,
        supplierId: supplier.id,
      );
      await _entityRepo.logMaterialPurchase(
        projectId: project.id,
        supplierId: supplier.id,
        transactionId: buy2,
        materialType: 'bricks',
        price: 70000,
        quantity: 5,
      );

      // Soft delete buy2
      await _ledgerRepo.softDeleteTransaction(buy2);

      final summary =
          await _ledgerRepo.projectEscalationSummary(project.id);
      final brick = summary.items.first;
      expect(brick.purchases, hasLength(1));
      expect(brick.purchases.first.id, mat1.id);
      expect(brick.escalationClaim, 0.0);
    });
  });
}
