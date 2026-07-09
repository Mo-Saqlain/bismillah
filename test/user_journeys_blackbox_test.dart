// Black-box tests modelling complete user journeys from "open the app
// fresh" through dozens of transactions to "close the project". Each
// scenario is what a real user would actually do in sequence — material
// buys, supplier payments, labour credits, project closes — and the
// assertions check the **observable outputs** the user sees on screen
// (cash position, profit, supplier owed, project archived, etc.).
//
// These complement the white-box invariants and the backup tests by
// proving the engine behaves correctly across long, realistic flows
// rather than single-call units.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bismillah_constructions/core/constants.dart';
import 'package:bismillah_constructions/data/db/local_db.dart';
import 'package:bismillah_constructions/data/repositories/entity_repository.dart';
import 'package:bismillah_constructions/data/repositories/ledger_repository.dart';

late Database _db;
late EntityRepository _entity;
late LedgerRepository _ledger;

Future<void> _resetDb() async {
  _db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 11,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  await LocalDb.instance.applySchemaForTests(_db);
  await _db.insert('app_settings',
      {'key': 'device_id', 'value': 'test-device'},
      conflictAlgorithm: ConflictAlgorithm.replace);
  _entity = EntityRepository(_db);
  _ledger = LedgerRepository(_db);
}

void main() {
  setUpAll(() => sqfliteFfiInit());
  setUp(_resetDb);
  tearDown(() async => _db.close());

  // ─────────────────────────────────────────────────────────────────────
  //  Journey 1: Profitable With-Material project from start to close
  // ─────────────────────────────────────────────────────────────────────

  test('Journey: profitable WM job from quote to archive', () async {
    // Day 1: client signs for 1.5M, pays 1M up front.
    final p = await _entity.createProject(
      name: 'Bahria Site',
      model: ProjectModel.withMaterial,
      clientName: 'Mr. Khan',
      budget: 1500000,
    );
    await _ledger.postReceiveFromProject(
        amount: 1000000, projectId: p.id, receivedInto: Accounts.cash);

    // Right after receiving — PoC says no fake profit.
    var income = await _ledger.incomeFigures();
    expect(income.netProfit, 0, reason: 'no costs yet → no profit');
    expect(income.wmDeposit, 1000000,
        reason: 'received money sits as deposit until earned');

    // Day 5-30: incurs costs over time.
    final steel = await _entity.createSupplier(name: 'Steelco');
    final workers = await _entity.createSupplier(name: 'Daily Workers');
    await _ledger.postMaterialBuy(
        amount: 600000, projectId: p.id, supplierId: steel.id);
    await _ledger.postLabourCredit(
        amount: 200000, projectId: p.id, supplierId: workers.id);

    // Mid-project — costs being recognized as costs are incurred.
    income = await _ledger.incomeFigures();
    expect(income.matCosts, 600000);
    expect(income.labCosts, 200000);
    expect(income.wmRevenue, 800000,
        reason: 'PoC: revenue tracks 800K of incurred costs');
    expect(income.wmDeposit, 200000,
        reason: '1M received − 800K earned = 200K still a deposit');
    expect(income.netProfit, 0,
        reason: 'cost-recovery: zero profit recognized in-progress');

    // Day 45: client pays the remaining 500K.
    await _ledger.postReceiveFromProject(
        amount: 500000, projectId: p.id, receivedInto: Accounts.cash);

    // Day 60: settle every supplier.
    await _ledger.postSupplierPay(
        amount: 600000,
        supplierId: steel.id,
        paidFrom: Accounts.cash,
        projectId: p.id);
    await _ledger.postSupplierPay(
        amount: 200000,
        supplierId: workers.id,
        paidFrom: Accounts.cash,
        projectId: p.id);

    // Cash position: 1M + 500K received − 800K paid out = 700K
    final cash = await _ledger.accountBalance(Accounts.cash.id);
    expect(cash, 700000);

    // Day 60: archive. Budget = 1.5M and received = 1.5M → archive succeeds.
    await _entity.archiveProject(p.id);
    final closed = await _entity.project(p.id);
    expect(closed!.archived, true);

    // Post-close P&L: full 1.5M revenue recognized, 800K costs → 700K profit.
    income = await _ledger.incomeFigures();
    expect(income.wmRevenue, 1500000);
    expect(income.netProfit, 700000,
        reason: 'profit = revenue 1.5M − costs 800K');
    expect(income.wmDeposit, 0);
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Journey 2: Project goes over budget — loss provision triggers
  // ─────────────────────────────────────────────────────────────────────

  test('Journey: cost overrun books loss provision before close', () async {
    final p = await _entity.createProject(
      name: 'Tight Margin Site',
      model: ProjectModel.withMaterial,
      budget: 100000,
    );
    final s = await _entity.createSupplier(name: 'Cementry');
    await _ledger.postReceiveFromProject(
        amount: 100000, projectId: p.id, receivedInto: Accounts.cash);
    await _ledger.postMaterialBuy(
        amount: 130000, projectId: p.id, supplierId: s.id);

    final income = await _ledger.incomeFigures();
    expect(income.lossProvision, 30000,
        reason: 'costs exceeded budget by 30K — must be booked now');
    expect(income.projectsAtRisk.length, 1);
    expect(income.projectsAtRisk.first.isOverBudget, true);
    // Net = 100K revenue (PoC capped at received since costs > received) −
    //       130K costs − 30K loss provision = -60K loss
    expect(income.netProfit, lessThan(0));
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Journey 3: Underpaid project — archive flow with budget resize
  // ─────────────────────────────────────────────────────────────────────

  test('Journey: customer pays less, user resizes budget to close', () async {
    final p = await _entity.createProject(
      name: 'Half-paid Site',
      model: ProjectModel.withMaterial,
      budget: 1000000,
    );
    final s = await _entity.createSupplier(name: 'Vendor');
    await _ledger.postReceiveFromProject(
        amount: 600000, projectId: p.id, receivedInto: Accounts.cash);
    await _ledger.postMaterialBuy(
        amount: 400000, projectId: p.id, supplierId: s.id);
    await _ledger.postSupplierPay(
        amount: 400000,
        supplierId: s.id,
        paidFrom: Accounts.cash,
        projectId: p.id);

    // Try to archive — should fail with budget mismatch (received < budget).
    Object? err;
    try {
      await _entity.archiveProject(p.id);
    } catch (e) {
      err = e;
    }
    expect(err, isA<ProjectBudgetMismatchException>());

    // User taps "Set budget to received" in the dialog.
    final mm = err as ProjectBudgetMismatchException;
    await _entity.updateProjectFields(p.id, budget: mm.received);
    await _entity.archiveProject(p.id);

    final closed = await _entity.project(p.id);
    expect(closed!.archived, true);
    expect(closed.budget, 600000);

    // Post-close: 600K revenue − 400K costs = 200K profit.
    final income = await _ledger.incomeFigures();
    expect(income.netProfit, 200000);
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Journey 4: Customer overpays — archive succeeds, deposit owed back
  // ─────────────────────────────────────────────────────────────────────

  test('Journey: customer overpays, archive proceeds, deposit liability stays',
      () async {
    final p = await _entity.createProject(
      name: 'Overpaid Site',
      model: ProjectModel.withMaterial,
      budget: 500000,
    );
    final s = await _entity.createSupplier(name: 'Vendor');
    await _ledger.postReceiveFromProject(
        amount: 700000, projectId: p.id, receivedInto: Accounts.cash);
    await _ledger.postMaterialBuy(
        amount: 300000, projectId: p.id, supplierId: s.id);
    await _ledger.postSupplierPay(
        amount: 300000,
        supplierId: s.id,
        paidFrom: Accounts.cash,
        projectId: p.id);

    // Archive with overpayment is allowed — the excess is a deposit owed back.
    await _entity.archiveProject(p.id);
    final closed = await _entity.project(p.id);
    expect(closed!.archived, true);

    final income = await _ledger.incomeFigures();
    expect(income.wmDeposit, 200000,
        reason: '700K received − 500K budget = 200K refund-able');
    expect(income.wmRevenue, 500000,
        reason: 'revenue capped at contract value');
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Journey 5: Labour credit then payment — the user-reported scenario
  // ─────────────────────────────────────────────────────────────────────

  test('Journey: labour credit + labour payment fully settles worker',
      () async {
    final p = await _entity.createProject(
      name: 'Labour Test',
      model: ProjectModel.withMaterial,
    );
    final w = await _entity.createSupplier(name: 'Mason');

    // Day 1: log wages owed (worker hasn't been paid yet).
    await _ledger.postLabourCredit(
        amount: 1500, projectId: p.id, supplierId: w.id);
    expect(await _ledger.supplierPayableBalance(w.id), 1500,
        reason: 'worker is owed 1500 after the credit');

    // Day 2: pay the worker. Smart-settle should retire the credit, NOT
    // double-book the cost.
    await _ledger.postLabourPayment(
        amount: 1500,
        projectId: p.id,
        supplierId: w.id,
        paidFrom: Accounts.cash);

    expect(await _ledger.supplierPayableBalance(w.id), 0,
        reason: 'worker is fully settled');
    expect(await _ledger.accountBalance(Accounts.labourCosts.id), 1500,
        reason: 'labour cost stays at 1500 — not 3000');
    expect(await _ledger.accountBalance(Accounts.cash.id), -1500,
        reason: 'cash actually went out');
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Journey 6: Multi-project ledger with concurrent suppliers
  // ─────────────────────────────────────────────────────────────────────

  test('Journey: two projects share a supplier — payables tracked correctly',
      () async {
    final p1 = await _entity.createProject(
      name: 'Site 1',
      model: ProjectModel.withMaterial,
    );
    final p2 = await _entity.createProject(
      name: 'Site 2',
      model: ProjectModel.withMaterial,
    );
    final shared = await _entity.createSupplier(name: 'Shared Vendor');

    await _ledger.postMaterialBuy(
        amount: 1000, projectId: p1.id, supplierId: shared.id);
    await _ledger.postMaterialBuy(
        amount: 2000, projectId: p2.id, supplierId: shared.id);

    // Single supplier, total payable = 3000 across both projects.
    expect(await _ledger.supplierPayableBalance(shared.id), 3000);

    // Pay 2500 — applied to global supplier balance.
    await _ledger.postSupplierPay(
        amount: 2500,
        supplierId: shared.id,
        paidFrom: Accounts.cash,
        projectId: p1.id);

    expect(await _ledger.supplierPayableBalance(shared.id), 500);
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Journey 7: Soft delete a transaction mid-project, verify P&L recovers
  // ─────────────────────────────────────────────────────────────────────

  test('Journey: accidental txn → soft delete → P&L returns to clean state',
      () async {
    final p = await _entity.createProject(
      name: 'Site',
      model: ProjectModel.withMaterial,
    );
    final s = await _entity.createSupplier(name: 'Vendor');

    // Real spend.
    await _ledger.postMaterialBuy(
        amount: 5000, projectId: p.id, supplierId: s.id);
    // Mistake: posted 50K instead of 5K.
    final mistake = await _ledger.postMaterialBuy(
        amount: 50000, projectId: p.id, supplierId: s.id);

    var mat = await _ledger.accountBalance(Accounts.materialCosts.id);
    expect(mat, 55000, reason: 'both posts visible before delete');

    await _ledger.softDeleteTransaction(mistake);

    mat = await _ledger.accountBalance(Accounts.materialCosts.id);
    expect(mat, 5000, reason: 'mistaken txn no longer affects P&L');

    final payable = await _ledger.supplierPayableBalance(s.id);
    expect(payable, 5000,
        reason: 'soft delete also reverses the offsetting credit');
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Journey 8: Wallet transfer + bank account flow
  // ─────────────────────────────────────────────────────────────────────

  test('Journey: receive into bank, transfer to cash, pay supplier',
      () async {
    final bank = await _entity.createBank(name: 'HBL');
    final p = await _entity.createProject(
      name: 'Site',
      model: ProjectModel.withMaterial,
    );
    final s = await _entity.createSupplier(name: 'Vendor');

    final bankAcc = Account(bank.id, bank.name, AccountType.asset);

    // Receive 100K into bank.
    await _ledger.postReceiveFromProject(
        amount: 100000, projectId: p.id, receivedInto: bankAcc);
    expect(await _ledger.accountBalance(bank.id), 100000);
    expect(await _ledger.accountBalance(Accounts.cash.id), 0);

    // Move 30K bank → cash.
    await _ledger.postWalletTransfer(
        amount: 30000, from: bankAcc, to: Accounts.cash);
    expect(await _ledger.accountBalance(bank.id), 70000);
    expect(await _ledger.accountBalance(Accounts.cash.id), 30000);

    // Buy material from cash, pay supplier from cash.
    await _ledger.postMaterialBuy(
        amount: 25000, projectId: p.id, supplierId: s.id);
    await _ledger.postSupplierPay(
        amount: 25000,
        supplierId: s.id,
        paidFrom: Accounts.cash,
        projectId: p.id);

    expect(await _ledger.accountBalance(Accounts.cash.id), 5000);
    expect(await _ledger.supplierPayableBalance(s.id), 0);
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Journey 9: Burn rate becomes meaningful as data accumulates
  // ─────────────────────────────────────────────────────────────────────

  test('Journey: single-day spend yields realistic burn rate', () async {
    final p = await _entity.createProject(
      name: 'Site',
      model: ProjectModel.withMaterial,
    );
    final s = await _entity.createSupplier(name: 'Vendor');

    expect(await _ledger.averageDailyExpense(), 0,
        reason: 'no spend → 0 burn (no division by zero)');

    await _ledger.postMaterialBuy(
        amount: 18000, projectId: p.id, supplierId: s.id);

    // One active spending day → that IS the daily burn rate (the
    // active-days fix for the user's "1700 days of runway" complaint).
    expect(await _ledger.averageDailyExpense(), 18000);
  });

  // ─────────────────────────────────────────────────────────────────────
  //  Journey 10: Receivables aging walks the FIFO queue per project
  // ─────────────────────────────────────────────────────────────────────

  test('Journey: project receivables shrink as customer pays', () async {
    final p = await _entity.createProject(
      name: 'Aging Test',
      model: ProjectModel.withMaterial,
    );
    final s = await _entity.createSupplier(name: 'Vendor');

    // Spend 50K on customer's behalf.
    await _ledger.postMaterialBuy(
        amount: 50000, projectId: p.id, supplierId: s.id);

    var receivables = await _ledger.receivablesTotals();
    expect(receivables.projectsOwed, 50000,
        reason: 'spent on customer, customer owes us 50K');

    // Customer pays 30K.
    await _ledger.postReceiveFromProject(
        amount: 30000, projectId: p.id, receivedInto: Accounts.cash);

    receivables = await _ledger.receivablesTotals();
    expect(receivables.projectsOwed, 20000,
        reason: 'still owed 50K − 30K = 20K');

    // Customer pays the rest plus extra.
    await _ledger.postReceiveFromProject(
        amount: 25000, projectId: p.id, receivedInto: Accounts.cash);

    receivables = await _ledger.receivablesTotals();
    expect(receivables.projectsOwed, 0,
        reason: 'fully paid → no project receivable');
  });
}
