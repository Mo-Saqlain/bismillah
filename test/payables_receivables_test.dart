import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/data/db/local_db.dart';
import 'package:bismillah_constructions/shared/data/models/payable_receivable_item.dart';
import 'package:bismillah_constructions/shared/data/repositories/entity_repository.dart';
import 'package:bismillah_constructions/shared/data/repositories/ledger_repository.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';

void main() {
  setUpAll(() => sqfliteFfiInit());

  late Database db;
  late EntityRepository entityRepo;
  late LedgerRepository ledgerRepo;
  late ProviderContainer container;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 5,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    await LocalDb.instance.applySchemaForTests(db);
    await db.insert(
      'app_settings',
      {'key': 'device_id', 'value': 'test-device-id'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    entityRepo = EntityRepository(db);
    ledgerRepo = LedgerRepository(db);

    container = ProviderContainer(
      overrides: [
        ledgerRepoProvider.overrideWith((_) async => ledgerRepo),
        entityRepoProvider.overrideWith((_) async => entityRepo),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('Payables & Receivables Hub aggregates all debt and receivable types', () async {
    // 1. Setup entities
    final supplier1 = await entityRepo.createSupplier(name: 'Cement Supplier Co', phone: '03001234567');
    final supplier2 = await entityRepo.createSupplier(name: 'Steel Traders', phone: '03009876543');
    final project1 = await entityRepo.createProject(
      name: 'Villa Construction',
      model: ProjectModel.withMaterial,
      whatsapp: '03112223334',
    );
    final counter1 = await entityRepo.createCounterEntity(
      name: 'Brother Loan',
      type: CounterEntityType.receivable,
      amount: 15000,
    );
    final counter2 = await entityRepo.createCounterEntity(
      name: 'Site Advance',
      type: CounterEntityType.payable,
      amount: 5000,
    );

    // 2. Post Supplier Payable: buy 50,000 cement on credit
    await ledgerRepo.postMaterialBuy(
      supplierId: supplier1.id,
      amount: 50000,
      projectId: project1.id,
      description: 'Cement purchase on credit',
    );

    // 3. Post Supplier Overpayment: pay 20,000 advance to Steel Traders before billing
    await ledgerRepo.postSupplierPay(
      supplierId: supplier2.id,
      amount: 20000,
      paidFrom: Accounts.cash,
      description: 'Steel advance payment',
    );

    // 4. Project cost incurred (10,000 spent on project1) -> project receivable
    await ledgerRepo.postLabourPayment(
      projectId: project1.id,
      supplierId: supplier1.id,
      amount: 10000,
      paidFrom: Accounts.cash,
      description: 'Mason wage payment',
    );


    // 5. Fetch Payables & Receivables Bundle
    final bundle = await container.read(payablesReceivablesProvider.future);

    // Verify aggregates
    // Receivables: Project1 (50k material costs) + Supplier2 Overpay (20k) + Counter1 Recv (15k) = 85,000
    // Payables: Supplier1 Payable (50k buy - 10k labour settle = 40k) + Counter2 Pay (5k) = 45,000
    // Net Position: 85,000 - 45,000 = +40,000 (Net Creditor)
    expect(bundle.totalReceivables, closeTo(85000, 0.01));
    expect(bundle.totalPayables, closeTo(45000, 0.01));
    expect(bundle.netPosition, closeTo(40000, 0.01));


    // Verify items present
    expect(bundle.items.length, equals(5));

    final cementPayable = bundle.items.firstWhere((i) => i.targetId == supplier1.id);
    expect(cementPayable.name, equals('Cement Supplier Co'));
    expect(cementPayable.amount, closeTo(40000, 0.01));
    expect(cementPayable.direction, equals(PayableReceivableDirection.payable));
    expect(cementPayable.phone, equals('03001234567'));

    final steelOverpayment = bundle.items.firstWhere((i) => i.targetId == supplier2.id);
    expect(steelOverpayment.name, equals('Steel Traders'));
    expect(steelOverpayment.amount, closeTo(20000, 0.01));
    expect(steelOverpayment.direction, equals(PayableReceivableDirection.receivable));

    final projectRecv = bundle.items.firstWhere((i) => i.targetId == project1.id);
    expect(projectRecv.name, equals('Villa Construction'));
    expect(projectRecv.amount, closeTo(50000, 0.01));
    expect(projectRecv.direction, equals(PayableReceivableDirection.receivable));

    expect(projectRecv.phone, equals('03112223334'));

    final counterRecvItem = bundle.items.firstWhere((i) => i.targetId == counter1.id);
    expect(counterRecvItem.name, equals('Brother Loan'));
    expect(counterRecvItem.amount, closeTo(15000, 0.01));
    expect(counterRecvItem.direction, equals(PayableReceivableDirection.receivable));

    final counterPayItem = bundle.items.firstWhere((i) => i.targetId == counter2.id);
    expect(counterPayItem.name, equals('Site Advance'));
    expect(counterPayItem.amount, closeTo(5000, 0.01));
    expect(counterPayItem.direction, equals(PayableReceivableDirection.payable));
  });
}
