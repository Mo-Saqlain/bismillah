// Comprehensive invariants & business-logic test suite.
//
// Updated for the post-customer-removal model:
//   • clientBilling / receivePayment(customerId) are gone
//   • new TxnKind.receiveFromProject does Dr Cash / Cr Project Revenue
//   • banks are user-defined rows in the `banks` table, not hardcoded constants
//   • reconciliation gate now: With-Material project archives blocked iff
//     supplier_payables > 0
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
  // Pre-populate a stable device_id so audit rows have it.
  await _db.insert('app_settings',
      {'key': 'device_id', 'value': 'test-device-uuid'},
      conflictAlgorithm: ConflictAlgorithm.replace);
  _entityRepo = EntityRepository(_db);
  _ledgerRepo = LedgerRepository(_db);
}

Future<String> _supplier(String name) async {
  final p = await _entityRepo.createSupplier(name: name);
  return p.id;
}

Future<String> _project(String name,
    {ProjectModel model = ProjectModel.withMaterial,
    String? clientName,
    double? budget,
    double? serviceFeePercent}) async {
  final pr = await _entityRepo.createProject(
    name: name,
    model: model,
    clientName: clientName,
    budget: budget,
    serviceFeePercent: serviceFeePercent,
  );
  return pr.id;
}

void main() {
  setUpAll(() => sqfliteFfiInit());
  setUp(_resetDb);
  tearDown(() async => _db.close());

  // -------------------------------------------------------------------
  // Financial engine
  // -------------------------------------------------------------------

  test('Double-Entry Integrity: materialBuy posts a balanced pair', () async {
    final sId = await _supplier('Steelco');
    final pId = await _project('Site A');

    final txnId = await _ledgerRepo.postMaterialBuy(
        amount: 1000, projectId: pId, supplierId: sId);

    final rows = await _db.query('journal_entries',
        where: 'transaction_id = ?', whereArgs: [txnId]);
    expect(rows.length, 2, reason: 'should write exactly 2 rows');

    final sumDebit =
        rows.fold<double>(0, (s, r) => s + (r['debit'] as num).toDouble());
    final sumCredit =
        rows.fold<double>(0, (s, r) => s + (r['credit'] as num).toDouble());
    expect(sumDebit - sumCredit, 0,
        reason: 'sum(debit) − sum(credit) must equal 0');
  });

  test('Profit Formula (With-Material): inflow − outflow = 3000', () async {
    final sId = await _supplier('Steelco');
    final pId = await _project('Site A', clientName: 'Acme');

    // 10,000 received directly from project.
    await _ledgerRepo.postReceiveFromProject(
        amount: 10000, projectId: pId, receivedInto: Accounts.cash);
    // 7,000 of material costs.
    await _ledgerRepo.postMaterialBuy(
        amount: 7000, projectId: pId, supplierId: sId);

    final rev = await _ledgerRepo.creditBalance(Accounts.projectRevenue.id,
        projectId: pId);
    final outflow = await _ledgerRepo.projectOutflow(pId);
    expect(rev, 10000);
    expect(outflow, 7000);
    expect(rev - outflow, 3000);
  });

  test('Profit Formula (Labour-Rate): outflow × 10% = 1000', () async {
    final sId = await _supplier('Workforce');
    final pId = await _project('Labour Site',
        model: ProjectModel.labourRate,
        clientName: 'Acme',
        serviceFeePercent: 10);

    await _ledgerRepo.postLabourPayment(
        amount: 10000,
        projectId: pId,
        supplierId: sId,
        paidFrom: Accounts.cash);

    final outflow = await _ledgerRepo.projectOutflow(pId);
    final fee = outflow * 0.10;
    expect(outflow, 10000);
    expect(fee, 1000);
  });

  test('Net Liquidity: Liquid_Cash − Payables = 3000', () async {
    final sId = await _supplier('Steelco');
    final pId = await _project('Site A');

    // 5,000 cash received from project.
    await _ledgerRepo.postReceiveFromProject(
        amount: 5000, projectId: pId, receivedInto: Accounts.cash);
    // 2,000 of supplier payables.
    await _ledgerRepo.postMaterialBuy(
        amount: 2000, projectId: pId, supplierId: sId);

    final liquid = await _ledgerRepo.accountBalance(Accounts.cash.id);
    final payables =
        await _ledgerRepo.creditBalance(Accounts.supplierPayables.id);

    expect(liquid, 5000);
    expect(payables, 2000);
    expect(liquid - payables, 3000);
  });

  // -------------------------------------------------------------------
  // Reconciliation gate
  // -------------------------------------------------------------------

  test('Reconciliation Gate: With-Material with open payables blocks archive',
      () async {
    final sId = await _supplier('Steelco');
    final pId = await _project('Site A');

    // 2,000 of supplier payables, none paid → blocks archive.
    await _ledgerRepo.postMaterialBuy(
        amount: 2000, projectId: pId, supplierId: sId);

    expect(
      () => _entityRepo.archiveProject(pId),
      throwsA(isA<ReconciliationException>()),
    );

    final still = await _entityRepo.project(pId);
    expect(still!.archived, false);
  });

  test('Reconciliation Gate: With-Material archives once payables are settled',
      () async {
    final sId = await _supplier('Steelco');
    final pId = await _project('Site A');

    await _ledgerRepo.postMaterialBuy(
        amount: 2000, projectId: pId, supplierId: sId);
    // Settle the payable from cash.
    await _ledgerRepo.postSupplierPay(
        amount: 2000,
        supplierId: sId,
        paidFrom: Accounts.cash,
        projectId: pId);

    await _entityRepo.archiveProject(pId);
    final after = await _entityRepo.project(pId);
    expect(after!.archived, true);
  });

  test('Labour-Rate Gate: open ledger blocks archive (pass-through model)',
      () async {
    // LR is pass-through — customer money is a deposit, not income.
    // Posting just a labour cost without revenue leaves the ledger
    // unbalanced (cost > revenue) so archive must be blocked.
    final sId = await _supplier('Workforce');
    final pId = await _project('Labour Site',
        model: ProjectModel.labourRate,
        clientName: 'Acme',
        serviceFeePercent: 10);

    await _ledgerRepo.postLabourPayment(
        amount: 1000,
        projectId: pId,
        supplierId: sId,
        paidFrom: Accounts.cash);

    expect(
      () => _entityRepo.archiveProject(pId),
      throwsA(isA<LabourRateUnsettledException>()),
    );
    final after = await _entityRepo.project(pId);
    expect(after!.archived, false,
        reason: 'LR archive blocked while customer money is unsettled');
  });

  test('Labour-Rate Gate: balanced ledger allows archive', () async {
    // Customer prepays exactly what's needed, fee is reclassified, no
    // residual to settle → archive succeeds.
    final sId = await _supplier('Workforce');
    final pId = await _project('Labour Site',
        model: ProjectModel.labourRate,
        clientName: 'Acme',
        serviceFeePercent: 10);

    // Customer prepays 1100 (1000 cost + 100 fee).
    await _ledgerRepo.postReceiveFromProject(
        amount: 1100, projectId: pId, receivedInto: Accounts.cash);
    await _ledgerRepo.postLabourPayment(
        amount: 1000,
        projectId: pId,
        supplierId: sId,
        paidFrom: Accounts.cash);
    // Service-fee reclassification: Dr Project Revenue 100 / Cr Service
    // Fee Income 100. Project ledger now nets to zero.
    await _ledgerRepo.postProjectServiceFee(
        projectId: pId, amount: 100);

    await _entityRepo.archiveProject(pId);
    final after = await _entityRepo.project(pId);
    expect(after!.archived, true);
  });

  // -------------------------------------------------------------------
  // Soft delete + hard delete
  // -------------------------------------------------------------------

  test('Soft Delete Visibility: deleted txn is excluded from P&L', () async {
    final pId = await _project('Site A');

    final txnId = await _ledgerRepo.postReceiveFromProject(
        amount: 1000, projectId: pId, receivedInto: Accounts.cash);

    var rev = await _ledgerRepo.creditBalance(Accounts.projectRevenue.id);
    expect(rev, 1000, reason: 'pre-delete revenue should be 1000');

    await _ledgerRepo.softDeleteTransaction(txnId);

    rev = await _ledgerRepo.creditBalance(Accounts.projectRevenue.id);
    expect(rev, 0, reason: 'post-delete revenue should drop to 0');
  });

  test('Hard Delete: removes both rows AND keeps audit row in change_log',
      () async {
    final pId = await _project('Site A');
    final txnId = await _ledgerRepo.postReceiveFromProject(
        amount: 1000, projectId: pId, receivedInto: Accounts.cash);

    await _ledgerRepo.hardDeleteTransaction(txnId);

    final remaining = await _db.query('journal_entries',
        where: 'transaction_id = ?', whereArgs: [txnId]);
    expect(remaining, isEmpty,
        reason: 'hard delete must remove both ledger rows');

    // Scope to the delete row: creation is now also audited (a `create` row
    // is written when the transaction is first posted), so an unscoped query
    // would return both.
    final audit = await _db.query('change_log',
        where: 'entity_id = ? AND action = ?',
        whereArgs: [txnId, ChangeAction.delete.db]);
    expect(audit, hasLength(1));
    expect(audit.first['action'], ChangeAction.delete.db);
    expect(audit.first['original_data'], contains('1000'));
  });

  // -------------------------------------------------------------------
  // Persistence & sync
  // -------------------------------------------------------------------

  test(
      'Aging Analysis (Payables): T-15 / T-45 / T-100 days bucketed correctly',
      () async {
    final sId = await _supplier('Steelco');
    final pId = await _project('Site A');

    // Three open payables at different ages — drop straight into journal_entries
    // so we can backdate created_at (the repo uses now()).
    final now = DateTime.now().toUtc();
    Future<void> bill(double amount, int daysAgo) async {
      final ts = now.subtract(Duration(days: daysAgo));
      final txnId = 'txn-$daysAgo';
      // Dr Material Costs / Cr Supplier Payables (the materialBuy posting).
      await _db.insert('journal_entries', {
        'id': 'je-${daysAgo}d-dr',
        'transaction_id': txnId,
        'account_id': Accounts.materialCosts.id,
        'project_id': pId,
        'supplier_id': sId,
        'debit': amount,
        'credit': 0,
        'created_at': ts.toIso8601String(),
        'is_deleted': 0,
        'synced': 0,
      });
      await _db.insert('journal_entries', {
        'id': 'je-${daysAgo}d-cr',
        'transaction_id': txnId,
        'account_id': Accounts.supplierPayables.id,
        'project_id': pId,
        'supplier_id': sId,
        'debit': 0,
        'credit': amount,
        'created_at': ts.toIso8601String(),
        'is_deleted': 0,
        'synced': 0,
      });
    }

    await bill(100, 15);
    await bill(200, 45);
    await bill(300, 100);

    final report = await _ledgerRepo.aging(
        partyAccountId: Accounts.supplierPayables.id,
        asOf: now);

    expect(report.total0_30, 100);
    expect(report.total31_60, 200);
    expect(report.total61_90, 0);
    expect(report.total90Plus, 300);
    expect(report.grandTotal, 600);
  });

  test('Audit Traceability: edit captures original_data, new_data, deviceId',
      () async {
    final pId = await _project('Site A');

    await _entityRepo.logChange(
      entityType: 'project',
      entityId: pId,
      action: ChangeAction.edit,
      originalData: {'name': 'Site A'},
      newData: {'name': 'Site A — Phase 2'},
      note: 'rename for phase 2',
    );

    final rows = await _db.query('change_log',
        where: 'entity_id = ? AND action = ?',
        whereArgs: [pId, ChangeAction.edit.db]);
    expect(rows.length, 1);
    final row = rows.first;
    expect(row['original_data'], contains('Site A'));
    expect(row['new_data'], contains('Phase 2'));
    expect(row['device_id'], 'test-device-uuid');
    expect(row['note'], 'rename for phase 2');
  });

  // -------------------------------------------------------------------
  // Banks are dynamic
  // -------------------------------------------------------------------

  test('Bank used in transaction cannot be deleted', () async {
    final sId = await _supplier('Steelco');
    final pId = await _project('Site A');
    final bank = await _entityRepo.createBank(name: 'Test Bank');

    // Pay using the new bank — its id becomes a journal account_id.
    await _ledgerRepo.postLabourPayment(
        amount: 100,
        projectId: pId,
        supplierId: sId,
        paidFrom: Account(bank.id, bank.name, AccountType.asset));

    expect(() => _entityRepo.deleteBank(bank.id),
        throwsA(isA<StateError>()),
        reason: 'cannot orphan an account_id referenced by journal_entries');
  });

  test('Unused bank can be deleted', () async {
    final bank = await _entityRepo.createBank(name: 'Unused Wallet');
    await _entityRepo.deleteBank(bank.id);
    final found = await _entityRepo.bank(bank.id);
    expect(found, isNull);
  });
}
