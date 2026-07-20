// White-box business-logic tests for the accounting changes added in this
// session: PoC revenue recognition, smart labour-payment settlement, the
// budget-mismatch archive gate, active-days burn rate, and the supplier
// payable helper. Each test pokes the production code via the public repo
// API, then asserts on the resulting journal_entries / Project state — no
// mocks, no UI — so they double as a regression suite for the engine.
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
  await _db.insert('app_settings',
      {'key': 'device_id', 'value': 'test-device-uuid'},
      conflictAlgorithm: ConflictAlgorithm.replace);
  _entityRepo = EntityRepository(_db);
  _ledgerRepo = LedgerRepository(_db);
}

Future<String> _supplier(String name) async =>
    (await _entityRepo.createSupplier(name: name)).id;

Future<String> _project(String name,
    {ProjectModel model = ProjectModel.withMaterial,
    String? clientName,
    double? budget,
    double? serviceFeePercent}) async {
  final p = await _entityRepo.createProject(
    name: name,
    model: model,
    clientName: clientName,
    budget: budget,
    serviceFeePercent: serviceFeePercent,
  );
  return p.id;
}

void main() {
  setUpAll(() => sqfliteFfiInit());
  setUp(_resetDb);
  tearDown(() async => _db.close());

  // ───────────────────────────────────────────────────────────────────────
  //  PoC revenue recognition — incomeFigures()
  // ───────────────────────────────────────────────────────────────────────

  // ───────────────────────────────────────────────────────────────────────
  //  Project model switch (With-Material <-> Labour-Rate, post-creation)
  // ───────────────────────────────────────────────────────────────────────

  group('Project model switch', () {
    test('WM→LR re-derives recognition and persists the new model', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Flex Site', budget: 1000000);
      await _ledgerRepo.postReceiveFromProject(
          amount: 1000000, projectId: pId, receivedInto: Accounts.cash);
      await _ledgerRepo.postMaterialBuy(
          amount: 400000, projectId: pId, supplierId: sId);

      // As With-Material: cost-recovery recognizes revenue up to costs.
      final before = await _ledgerRepo.incomeFigures();
      expect(before.wmRevenue, 400000);
      expect(before.wmDeposit, 600000);
      expect(before.lrDeposit, 0);

      await _entityRepo.updateProjectFields(pId,
          model: ProjectModel.labourRate);
      expect((await _entityRepo.project(pId))!.model, ProjectModel.labourRate);

      // Recognition re-derives with zero stored state: the WM cost-recovery
      // revenue disappears and the customer money becomes an LR deposit.
      final after = await _ledgerRepo.incomeFigures();
      expect(after.wmRevenue, 0);
      expect(after.wmDeposit, 0);
      expect(after.lrDeposit, 600000);
      expect(after.matCosts, 400000,
          reason: 'costs are untouched by a reclassification');
    });

    test('A model switch is audited in the change log', () async {
      final pId = await _project('Audited Site', budget: 500000);
      final createRows = await _db
          .query('change_log', where: 'entity_id = ?', whereArgs: [pId]);
      expect(createRows.length, 1, reason: 'createProject logs one row');

      await _entityRepo.updateProjectFields(pId,
          model: ProjectModel.labourRate);

      final afterRows = await _db
          .query('change_log', where: 'entity_id = ?', whereArgs: [pId]);
      expect(afterRows.length, 2, reason: 'the model switch adds an edit row');
    });

    test('Ordinary field edits are NOT logged (no activity-log spam)',
        () async {
      final pId = await _project('Quiet Site', budget: 500000);
      await _entityRepo.updateProjectCompletion(pId, 60);
      await _entityRepo.updateProjectFields(pId, name: 'Quiet Site Renamed');

      final rows = await _db
          .query('change_log', where: 'entity_id = ?', whereArgs: [pId]);
      expect(rows.length, 1,
          reason: 'only the create row — field edits stay unlogged');
    });
  });

  group('PoC revenue recognition', () {
    test('Active WM: 0 costs + 1M received → 0 revenue, 1M deposit', () async {
      final pId = await _project('Site A', budget: 1500000);
      await _ledgerRepo.postReceiveFromProject(
          amount: 1000000, projectId: pId, receivedInto: Accounts.cash);

      final f = await _ledgerRepo.incomeFigures();
      expect(f.wmRevenue, 0,
          reason: 'no costs incurred yet → no revenue recognized');
      expect(f.wmDeposit, 1000000,
          reason: 'received money is a deposit liability until earned');
      expect(f.netProfit, 0,
          reason: 'no fake profit from advance customer payments');
    });

    test('Active WM: 500K costs + 1M received → 500K revenue, 500K deposit',
        () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A', budget: 1500000);
      await _ledgerRepo.postReceiveFromProject(
          amount: 1000000, projectId: pId, receivedInto: Accounts.cash);
      await _ledgerRepo.postMaterialBuy(
          amount: 500000, projectId: pId, supplierId: sId);

      final f = await _ledgerRepo.incomeFigures();
      expect(f.wmRevenue, 500000,
          reason: 'cost-recovery: revenue tracks costs');
      expect(f.wmDeposit, 500000,
          reason: 'unearned excess sits as deposit');
      expect(f.matCosts, 500000);
      expect(f.netProfit, 0,
          reason: 'gross profit not booked until project closes');
    });

    test('Active WM: costs == received → revenue == costs, no deposit',
        () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A', budget: 1500000);
      await _ledgerRepo.postReceiveFromProject(
          amount: 800000, projectId: pId, receivedInto: Accounts.cash);
      await _ledgerRepo.postMaterialBuy(
          amount: 800000, projectId: pId, supplierId: sId);

      final f = await _ledgerRepo.incomeFigures();
      expect(f.wmRevenue, 800000);
      expect(f.wmDeposit, 0);
    });

    test('Closed WM: archive recognizes full contract revenue', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A', budget: 1000000);
      await _ledgerRepo.postReceiveFromProject(
          amount: 1000000, projectId: pId, receivedInto: Accounts.cash);
      await _ledgerRepo.postMaterialBuy(
          amount: 600000, projectId: pId, supplierId: sId);
      await _ledgerRepo.postSupplierPay(
          amount: 600000,
          supplierId: sId,
          paidFrom: Accounts.cash,
          projectId: pId);
      await _entityRepo.archiveProject(pId);

      final f = await _ledgerRepo.incomeFigures();
      expect(f.wmRevenue, 1000000,
          reason: 'closed project recognizes full received as revenue');
      expect(f.wmDeposit, 0);
      // Net profit = 1M revenue − 600K costs = 400K
      expect(f.netProfit, 400000);
    });

    test('Loss provision: costs > budget books the excess immediately',
        () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Tight Site', budget: 100000);
      await _ledgerRepo.postReceiveFromProject(
          amount: 100000, projectId: pId, receivedInto: Accounts.cash);
      await _ledgerRepo.postMaterialBuy(
          amount: 150000, projectId: pId, supplierId: sId);

      final f = await _ledgerRepo.incomeFigures();
      // Costs (150K) > budget (100K) → 50K loss provision recognized
      expect(f.lossProvision, 50000,
          reason: 'GAAP/IFRS: future losses booked the moment they are probable');
      expect(f.totalCosts, greaterThanOrEqualTo(150000 + 50000));
    });

    test('No loss provision when costs ≤ budget', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Healthy Site', budget: 1000000);
      await _ledgerRepo.postMaterialBuy(
          amount: 500000, projectId: pId, supplierId: sId);

      final f = await _ledgerRepo.incomeFigures();
      expect(f.lossProvision, 0);
    });

    test('Projects at risk: ≥ 80% threshold, sorted by severity', () async {
      final sId = await _supplier('Steelco');
      final low = await _project('Low Use', budget: 100000);
      final medium = await _project('Approaching', budget: 100000);
      final over = await _project('Over Budget', budget: 100000);

      // 50% — below threshold, not at risk
      await _ledgerRepo.postMaterialBuy(
          amount: 50000, projectId: low, supplierId: sId);
      // 85% — at risk warning
      await _ledgerRepo.postMaterialBuy(
          amount: 85000, projectId: medium, supplierId: sId);
      // 130% — over budget
      await _ledgerRepo.postMaterialBuy(
          amount: 130000, projectId: over, supplierId: sId);

      final f = await _ledgerRepo.incomeFigures();
      expect(f.projectsAtRisk.length, 2,
          reason: 'only ≥80% projects appear');
      expect(f.projectsAtRisk.first.isOverBudget, true,
          reason: 'over-budget items sorted first');
      expect(f.projectsAtRisk.first.projectId, over);
      expect(f.projectsAtRisk[1].projectId, medium);
      expect(f.projectsAtRisk.any((r) => r.projectId == low), false);
    });

    test('Labour-Rate: deposit owed back when received > costs', () async {
      final sId = await _supplier('Workforce');
      final pId = await _project('Labour Site',
          model: ProjectModel.labourRate,
          clientName: 'Acme',
          serviceFeePercent: 10);

      await _ledgerRepo.postReceiveFromProject(
          amount: 500000, projectId: pId, receivedInto: Accounts.cash);
      await _ledgerRepo.postLabourPayment(
          amount: 300000,
          projectId: pId,
          supplierId: sId,
          paidFrom: Accounts.cash);

      final f = await _ledgerRepo.incomeFigures();
      // 500K received − 300K costs = 200K residual still owed back to customer
      expect(f.lrDeposit, 200000);
      // Service fee not yet posted — still 0
      expect(f.serviceFees, 0);
    });

    test('Mixed WM + LR: aggregates both correctly', () async {
      final sId1 = await _supplier('Steelco');
      final sId2 = await _supplier('Workforce');
      final wm = await _project('WM Site', budget: 1000000);
      final lr = await _project('LR Site',
          model: ProjectModel.labourRate, serviceFeePercent: 10);

      await _ledgerRepo.postReceiveFromProject(
          amount: 800000, projectId: wm, receivedInto: Accounts.cash);
      await _ledgerRepo.postMaterialBuy(
          amount: 200000, projectId: wm, supplierId: sId1);

      await _ledgerRepo.postReceiveFromProject(
          amount: 300000, projectId: lr, receivedInto: Accounts.cash);
      await _ledgerRepo.postLabourPayment(
          amount: 250000,
          projectId: lr,
          supplierId: sId2,
          paidFrom: Accounts.cash);

      final f = await _ledgerRepo.incomeFigures();
      expect(f.wmRevenue, 200000, reason: 'PoC: only matched-by-cost portion');
      expect(f.wmDeposit, 600000, reason: 'WM excess as deposit');
      expect(f.lrDeposit, 50000, reason: 'LR residual after costs');
      expect(f.matCosts, 200000);
      expect(f.labCosts, 250000);
    });

    test('Per-project filtering: incomeFigures(projectId) scopes correctly',
        () async {
      final sId = await _supplier('Steelco');
      final p1 = await _project('Site 1', budget: 100000);
      final p2 = await _project('Site 2', budget: 200000);

      await _ledgerRepo.postMaterialBuy(
          amount: 30000, projectId: p1, supplierId: sId);
      await _ledgerRepo.postMaterialBuy(
          amount: 50000, projectId: p2, supplierId: sId);

      final scoped = await _ledgerRepo.incomeFigures(projectId: p1);
      expect(scoped.matCosts, 30000,
          reason: 'project filter excludes other projects');
      // Personal draw is null when scoped to a single project
      expect(scoped.personalDraw, 0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  //  postLabourPayment — smart settlement of outstanding wage credit
  // ───────────────────────────────────────────────────────────────────────

  group('postLabourPayment smart settlement', () {
    test('No outstanding credit: posts direct labour cost', () async {
      final sId = await _supplier('Worker A');
      final pId = await _project('Site A');

      await _ledgerRepo.postLabourPayment(
          amount: 1000,
          projectId: pId,
          supplierId: sId,
          paidFrom: Accounts.cash);

      final labour = await _ledgerRepo.accountBalance(Accounts.labourCosts.id);
      final payable = await _ledgerRepo.supplierPayableBalance(sId);
      expect(labour, 1000, reason: 'direct labour cost booked');
      expect(payable, 0, reason: 'no payable touched');
    });

    test('Payment ≤ owed: settles payable, NO new labour cost', () async {
      final sId = await _supplier('Worker B');
      final pId = await _project('Site A');

      // Record 1500 wages on credit first.
      await _ledgerRepo.postLabourCredit(
          amount: 1500, projectId: pId, supplierId: sId);
      // Then pay exactly 1500.
      await _ledgerRepo.postLabourPayment(
          amount: 1500,
          projectId: pId,
          supplierId: sId,
          paidFrom: Accounts.cash);

      final labour = await _ledgerRepo.accountBalance(Accounts.labourCosts.id);
      final payable = await _ledgerRepo.supplierPayableBalance(sId);
      expect(labour, 1500,
          reason: 'cost was booked at credit time — should NOT double up');
      expect(payable, 0,
          reason: 'payment fully settles the outstanding wage');
    });

    test('Payment > owed: settles + books excess as new direct cost',
        () async {
      final sId = await _supplier('Worker C');
      final pId = await _project('Site A');

      await _ledgerRepo.postLabourCredit(
          amount: 1000, projectId: pId, supplierId: sId);
      // Pay 1500 — settles 1000 + 500 new cost.
      await _ledgerRepo.postLabourPayment(
          amount: 1500,
          projectId: pId,
          supplierId: sId,
          paidFrom: Accounts.cash);

      final labour = await _ledgerRepo.accountBalance(Accounts.labourCosts.id);
      final payable = await _ledgerRepo.supplierPayableBalance(sId);
      expect(labour, 1500, reason: '1000 from credit + 500 new');
      expect(payable, 0, reason: 'old credit fully settled');
    });

    test('Partial payment: settles payable up to amount, no new cost',
        () async {
      final sId = await _supplier('Worker D');
      final pId = await _project('Site A');

      await _ledgerRepo.postLabourCredit(
          amount: 2000, projectId: pId, supplierId: sId);
      // Pay only 800 — settles 800 of the 2000 owed, no new cost.
      await _ledgerRepo.postLabourPayment(
          amount: 800,
          projectId: pId,
          supplierId: sId,
          paidFrom: Accounts.cash);

      final labour = await _ledgerRepo.accountBalance(Accounts.labourCosts.id);
      final payable = await _ledgerRepo.supplierPayableBalance(sId);
      expect(labour, 2000, reason: 'cost stays at original credit amount');
      expect(payable, 1200, reason: '2000 owed − 800 paid = 1200 still owed');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  //  Archive gate — Budget vs Received mismatch (With-Material)
  // ───────────────────────────────────────────────────────────────────────

  group('Budget-mismatch archive gate', () {
    test('WM received < budget → ProjectBudgetMismatchException', () async {
      final pId = await _project('Underpaid', budget: 1500000);
      await _ledgerRepo.postReceiveFromProject(
          amount: 1000000, projectId: pId, receivedInto: Accounts.cash);

      expect(
        () => _entityRepo.archiveProject(pId),
        throwsA(isA<ProjectBudgetMismatchException>()
            .having((e) => e.budget, 'budget', 1500000)
            .having((e) => e.received, 'received', 1000000)
            .having((e) => e.shortfall, 'shortfall', 500000)),
      );
    });

    test('WM received == budget → archives cleanly', () async {
      final pId = await _project('Exact', budget: 500000);
      await _ledgerRepo.postReceiveFromProject(
          amount: 500000, projectId: pId, receivedInto: Accounts.cash);

      await _entityRepo.archiveProject(pId);
      final p = await _entityRepo.project(pId);
      expect(p!.archived, true);
    });

    test('WM received > budget (overpayment) → archives, deposit owed back',
        () async {
      final pId = await _project('Overpaid', budget: 500000);
      await _ledgerRepo.postReceiveFromProject(
          amount: 700000, projectId: pId, receivedInto: Accounts.cash);

      await _entityRepo.archiveProject(pId);
      final p = await _entityRepo.project(pId);
      expect(p!.archived, true,
          reason: 'overpayment is allowed — excess is a deposit liability');

      final f = await _ledgerRepo.incomeFigures();
      expect(f.wmDeposit, 200000,
          reason: 'excess over budget is owed back to customer');
    });

    test('WM with no budget set → no gate, archives freely', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('No budget'); // budget = null
      await _ledgerRepo.postMaterialBuy(
          amount: 1000, projectId: pId, supplierId: sId);
      await _ledgerRepo.postSupplierPay(
          amount: 1000,
          supplierId: sId,
          paidFrom: Accounts.cash,
          projectId: pId);

      await _entityRepo.archiveProject(pId);
      final p = await _entityRepo.project(pId);
      expect(p!.archived, true);
    });

    test('Labour-Rate ignores budget gate even when underpaid', () async {
      final sId = await _supplier('Workforce');
      final pId = await _project('LR Site',
          model: ProjectModel.labourRate,
          clientName: 'Acme',
          serviceFeePercent: 10,
          budget: 1000000);
      // Customer paid less than budget — LR doesn't care about budget.
      await _ledgerRepo.postReceiveFromProject(
          amount: 500000, projectId: pId, receivedInto: Accounts.cash);
      await _ledgerRepo.postLabourPayment(
          amount: 500000,
          projectId: pId,
          supplierId: sId,
          paidFrom: Accounts.cash);

      await _entityRepo.archiveProject(pId);
      final p = await _entityRepo.project(pId);
      expect(p!.archived, true);
    });

    test('Open supplier payable still blocks WM archive', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A', budget: 100000);
      await _ledgerRepo.postReceiveFromProject(
          amount: 100000, projectId: pId, receivedInto: Accounts.cash);
      await _ledgerRepo.postMaterialBuy(
          amount: 50000, projectId: pId, supplierId: sId);
      // Note: supplier NOT paid → 50k still owed.

      expect(
        () => _entityRepo.archiveProject(pId),
        throwsA(isA<ReconciliationException>()),
      );
    });

    test('force: true bypasses both gates', () async {
      final pId = await _project('Underpaid', budget: 1500000);
      await _ledgerRepo.postReceiveFromProject(
          amount: 1000000, projectId: pId, receivedInto: Accounts.cash);

      // Should NOT throw with force=true (used by data-repair flows).
      await _entityRepo.archiveProject(pId, force: true);
      final p = await _entityRepo.project(pId);
      expect(p!.archived, true);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  //  Burn rate — averageDailyExpense uses ACTIVE days
  // ───────────────────────────────────────────────────────────────────────

  group('averageDailyExpense (active-days)', () {
    test('Single day of activity: total / 1 (not / 30)', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A');

      await _ledgerRepo.postMaterialBuy(
          amount: 18000, projectId: pId, supplierId: sId);

      final burn = await _ledgerRepo.averageDailyExpense();
      expect(burn, 18000,
          reason: 'one active day → that day IS the average');
    });

    test('No spending in window: 0 burn', () async {
      final burn = await _ledgerRepo.averageDailyExpense();
      expect(burn, 0,
          reason: 'no activity → no division-by-zero, returns 0');
    });

    test('Multiple distinct days: total / distinct days', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A');
      final today = DateTime.now().toUtc();

      // Backdated rows on three different days within the 30-day window.
      Future<void> backdated(double amt, int daysAgo) async {
        final ts = today.subtract(Duration(days: daysAgo)).toIso8601String();
        final txnId = 'bd-$daysAgo';
        await _db.insert('journal_entries', {
          'id': '$txnId-dr',
          'transaction_id': txnId,
          'account_id': Accounts.materialCosts.id,
          'project_id': pId,
          'supplier_id': sId,
          'debit': amt,
          'credit': 0,
          'created_at': ts,
          'is_deleted': 0,
          'synced': 0,
        });
        await _db.insert('journal_entries', {
          'id': '$txnId-cr',
          'transaction_id': txnId,
          'account_id': Accounts.supplierPayables.id,
          'project_id': pId,
          'supplier_id': sId,
          'debit': 0,
          'credit': amt,
          'created_at': ts,
          'is_deleted': 0,
          'synced': 0,
        });
      }

      await backdated(1000, 1);
      await backdated(2000, 5);
      await backdated(3000, 10);

      final burn = await _ledgerRepo.averageDailyExpense();
      expect(burn, 6000 / 3,
          reason: 'total 6000 over 3 active days → 2000/day average');
    });

    test('Soft-deleted rows excluded from burn rate', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A');

      final txnId = await _ledgerRepo.postMaterialBuy(
          amount: 5000, projectId: pId, supplierId: sId);
      await _ledgerRepo.softDeleteTransaction(txnId);

      final burn = await _ledgerRepo.averageDailyExpense();
      expect(burn, 0, reason: 'deleted txns must not feed the rate');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  //  supplierPayableBalance — per-supplier scoping
  // ───────────────────────────────────────────────────────────────────────

  group('supplierPayableBalance', () {
    test('Material buy raises balance, supplier pay clears it', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A');

      expect(await _ledgerRepo.supplierPayableBalance(sId), 0);

      await _ledgerRepo.postMaterialBuy(
          amount: 2500, projectId: pId, supplierId: sId);
      expect(await _ledgerRepo.supplierPayableBalance(sId), 2500);

      await _ledgerRepo.postSupplierPay(
          amount: 1000,
          supplierId: sId,
          paidFrom: Accounts.cash,
          projectId: pId);
      expect(await _ledgerRepo.supplierPayableBalance(sId), 1500);
    });

    test('Overpayment yields negative balance (we paid too much)', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A');

      await _ledgerRepo.postMaterialBuy(
          amount: 1000, projectId: pId, supplierId: sId);
      await _ledgerRepo.postSupplierPay(
          amount: 1500,
          supplierId: sId,
          paidFrom: Accounts.cash,
          projectId: pId);

      expect(await _ledgerRepo.supplierPayableBalance(sId), -500,
          reason: 'overpayment shows up as negative payable (an asset)');
    });

    test('Different suppliers tracked separately', () async {
      final s1 = await _supplier('Steelco');
      final s2 = await _supplier('Cementry');
      final pId = await _project('Site A');

      await _ledgerRepo.postMaterialBuy(
          amount: 1000, projectId: pId, supplierId: s1);
      await _ledgerRepo.postMaterialBuy(
          amount: 2000, projectId: pId, supplierId: s2);

      expect(await _ledgerRepo.supplierPayableBalance(s1), 1000);
      expect(await _ledgerRepo.supplierPayableBalance(s2), 2000);
    });

    test('Soft-deleted entries excluded', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A');

      final txnId = await _ledgerRepo.postMaterialBuy(
          amount: 1000, projectId: pId, supplierId: sId);
      expect(await _ledgerRepo.supplierPayableBalance(sId), 1000);

      await _ledgerRepo.softDeleteTransaction(txnId);
      expect(await _ledgerRepo.supplierPayableBalance(sId), 0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  //  End-to-end: the user's exact reported scenarios
  // ───────────────────────────────────────────────────────────────────────

  group('End-to-end regression scenarios', () {
    test('User scenario: 1500 labour-on-credit + 1500 labour-payment → 0 owed',
        () async {
      // Reproduces the exact bug the user reported on 2026-05-08.
      final sId = await _supplier('Worker');
      final pId = await _project('Site A');

      await _ledgerRepo.postLabourCredit(
          amount: 1500, projectId: pId, supplierId: sId);
      await _ledgerRepo.postLabourPayment(
          amount: 1500,
          projectId: pId,
          supplierId: sId,
          paidFrom: Accounts.cash);

      // BEFORE fix: labour=3000, payable=1500 (worker still showing 1500 owed).
      // AFTER fix : labour=1500, payable=0.
      expect(await _ledgerRepo.accountBalance(Accounts.labourCosts.id), 1500);
      expect(await _ledgerRepo.supplierPayableBalance(sId), 0);
    });

    test('User scenario: 1.5M budget, 1M received, archive → mismatch dialog',
        () async {
      final pId = await _project('Site A', budget: 1500000);
      await _ledgerRepo.postReceiveFromProject(
          amount: 1000000, projectId: pId, receivedInto: Accounts.cash);

      // The exception path the UI catches to show the "set budget to received"
      // dialog.
      Object? caught;
      try {
        await _entityRepo.archiveProject(pId);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<ProjectBudgetMismatchException>());
      final mm = caught as ProjectBudgetMismatchException;
      expect(mm.shortfall, 500000);

      // Backend remediation path: user resizes the budget (now done via
      // Manage → Edit Project rather than the archive dialog) and tries
      // archive again.
      await _entityRepo.updateProjectFields(pId, budget: mm.received);
      await _entityRepo.archiveProject(pId);

      final p = await _entityRepo.project(pId);
      expect(p!.archived, true);
      expect(p.budget, 1000000);
    });

    test(
        'User scenario: 3M received → 72K cost → supplier paid → NOT in '
        'receivables (FIFO prepayment carry-forward)', () async {
      // Reproduces the exact bug the user reported on 2026-05-08:
      // After receiving 3M and spending 72K (supplier paid in full), the
      // dashboard showed 72K in receivables. The FIFO matcher had
      // discarded the customer's prepayment, then queued the later cost
      // as "owed by customer".
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A', budget: 15000000);

      // Customer prepays before any work.
      await _ledgerRepo.postReceiveFromProject(
          amount: 3000000, projectId: pId, receivedInto: Accounts.cash);
      // Then a single material buy + settlement.
      await _ledgerRepo.postMaterialBuy(
          amount: 72000, projectId: pId, supplierId: sId);
      await _ledgerRepo.postSupplierPay(
          amount: 72000,
          supplierId: sId,
          paidFrom: Accounts.cash,
          projectId: pId);

      final r = await _ledgerRepo.receivablesTotals();
      expect(r.projectsOwed, 0,
          reason:
              'customer prepaid 3M — the 72K cost is fully covered, '
              'nothing should be flagged as owed');
      expect(r.suppliersOverpaid, 0,
          reason: 'supplier paid in full, no overpayment');
    });

    test(
        'Customer overpays then incurs costs: queue stays empty, '
        'prepayment bank tracks the overhang', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A', budget: 15000000);

      await _ledgerRepo.postReceiveFromProject(
          amount: 1000000, projectId: pId, receivedInto: Accounts.cash);
      // Multiple cost events, each smaller than the prepayment.
      await _ledgerRepo.postMaterialBuy(
          amount: 100000, projectId: pId, supplierId: sId);
      await _ledgerRepo.postMaterialBuy(
          amount: 200000, projectId: pId, supplierId: sId);

      final r = await _ledgerRepo.receivablesTotals();
      expect(r.projectsOwed, 0,
          reason: 'prepayment of 1M still covers the 300K of costs');
    });

    test(
        'Material price trend / BvA: soft delete hides the inventory row',
        () async {
      // User's reported scenario: buy material, then soft-delete the
      // transaction. The price-trend chart should NOT keep showing the
      // deleted purchase, and BvA should drop it from its breakdown.
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A', budget: 1000000);

      // Log a purchase directly via the entity repo so we can attach a
      // real transaction_id to the inventory row, mirroring the form's
      // happy path.
      final txnId = await _ledgerRepo.postMaterialBuy(
          amount: 50000, projectId: pId, supplierId: sId);
      await _entityRepo.logMaterialPurchase(
        projectId: pId,
        supplierId: sId,
        transactionId: txnId,
        materialType: 'Brick',
        price: 50000,
        quantity: 2500,
      );

      // Pre-delete: the trend has 1 data point, BvA shows 50K of Brick.
      var trend = await _ledgerRepo.priceTrend();
      expect(trend['Brick']?.length, 1);
      var bva = await _ledgerRepo.projectBva(pId);
      expect(bva.materialByType['Brick'], 50000);

      // Soft delete.
      await _ledgerRepo.softDeleteTransaction(txnId);

      // Post-delete: both surfaces must drop the row.
      trend = await _ledgerRepo.priceTrend();
      expect(trend['Brick'], anyOf(isNull, isEmpty),
          reason:
              'soft delete must remove the inventory row from price trend');
      bva = await _ledgerRepo.projectBva(pId);
      expect(bva.materialByType['Brick'], anyOf(isNull, 0),
          reason: 'soft delete must remove the inventory row from BvA');
    });

    test(
        'Material price trend / BvA: hard delete drops the inventory row',
        () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A', budget: 1000000);
      final txnId = await _ledgerRepo.postMaterialBuy(
          amount: 30000, projectId: pId, supplierId: sId);
      await _entityRepo.logMaterialPurchase(
        projectId: pId,
        supplierId: sId,
        transactionId: txnId,
        materialType: 'Cement',
        price: 30000,
        quantity: 60,
      );

      await _ledgerRepo.hardDeleteTransaction(txnId);

      final trend = await _ledgerRepo.priceTrend();
      expect(trend['Cement'], anyOf(isNull, isEmpty),
          reason:
              'hard delete must physically remove the inventory row');
      final bva = await _ledgerRepo.projectBva(pId);
      expect(bva.materialByType['Cement'], anyOf(isNull, 0));

      // And the inventory listing must not return the row either.
      final inv = await _entityRepo.materialInventory(projectId: pId);
      expect(inv.where((i) => i.transactionId == txnId), isEmpty);
    });

    test('Restore brings the inventory row back to price trend / BvA',
        () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A', budget: 1000000);
      final txnId = await _ledgerRepo.postMaterialBuy(
          amount: 40000, projectId: pId, supplierId: sId);
      await _entityRepo.logMaterialPurchase(
        projectId: pId,
        supplierId: sId,
        transactionId: txnId,
        materialType: 'Sarya',
        price: 40000,
        quantity: 200,
      );

      await _ledgerRepo.softDeleteTransaction(txnId);
      await _ledgerRepo.restoreTransaction(txnId);

      final trend = await _ledgerRepo.priceTrend();
      expect(trend['Sarya']?.length, 1,
          reason: 'restore re-enables the inventory row');
      final bva = await _ledgerRepo.projectBva(pId);
      expect(bva.materialByType['Sarya'], 40000);
    });

    test(
        'Quantity-less material buy: excluded from price trend, kept in BvA',
        () async {
      // v17: a material buy can be logged without a quantity. Such a buy
      // has no real per-unit rate, so it must NOT appear in the price
      // trend — but its cost still rolls up under its material type in the
      // Budget vs Actual breakdown (the detail lives in the memo).
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A', budget: 1000000);

      // One quantified buy (feeds the trend) and one without a quantity.
      final txnQty = await _ledgerRepo.postMaterialBuy(
          amount: 30000, projectId: pId, supplierId: sId);
      await _entityRepo.logMaterialPurchase(
        projectId: pId,
        supplierId: sId,
        transactionId: txnQty,
        materialType: 'Cement',
        price: 30000,
        quantity: 60,
      );
      final txnNoQty = await _ledgerRepo.postMaterialBuy(
          amount: 20000, projectId: pId, supplierId: sId);
      final item = await _entityRepo.logMaterialPurchase(
        projectId: pId,
        supplierId: sId,
        transactionId: txnNoQty,
        materialType: 'Cement',
        price: 20000,
        // quantity intentionally omitted.
      );

      // The row is persisted with null quantity / rate.
      expect(item.quantity, isNull);
      expect(item.rate, isNull);

      // Price trend only plots the quantified buy.
      final trend = await _ledgerRepo.priceTrend();
      expect(trend['Cement']?.length, 1,
          reason: 'quantity-less buy must not appear in the price trend');
      expect(trend['Cement']!.single.rate, closeTo(500, 0.01));

      // BvA still counts both — full 50K of Cement spend.
      final bva = await _ledgerRepo.projectBva(pId);
      expect(bva.materialByType['Cement'], 50000,
          reason: 'quantity-less buy still rolls up under its type');
    });

    test(
        'Mixed order: cost → prepayment → cost — prepayment consumes '
        'only what fits', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A', budget: 1000000);

      // Backdate three events so order matters.
      final now = DateTime.now().toUtc();
      Future<void> entry(
          double debit, double credit, String accountId, int daysAgo) async {
        final ts = now.subtract(Duration(days: daysAgo));
        final txnId = 'mx-$daysAgo';
        await _db.insert('journal_entries', {
          'id': '$txnId-a',
          'transaction_id': txnId,
          'account_id': accountId,
          'project_id': pId,
          'supplier_id': sId,
          'debit': debit,
          'credit': credit,
          'created_at': ts.toIso8601String(),
          'is_deleted': 0,
          'synced': 0,
        });
      }

      // T-10: cost 200K (queue=[200K], prepaid=0)
      await entry(200000, 0, Accounts.materialCosts.id, 10);
      // T-5: revenue 100K (queue=[100K] after consume, prepaid=0)
      await entry(0, 100000, Accounts.projectRevenue.id, 5);
      // T-1: cost 150K (queue=[100K, 150K], still nothing prepaid)
      await entry(150000, 0, Accounts.materialCosts.id, 1);

      final r = await _ledgerRepo.receivablesTotals();
      expect(r.projectsOwed, 250000,
          reason:
              '200K + 150K of costs − 100K customer payment = 250K still '
              'owed by customer');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  //  Duplicate-supplier merge (cleanup after cross-device double entry)
  // ───────────────────────────────────────────────────────────────────────

  group('Merge duplicate suppliers', () {
    test('finds same-name active suppliers, ignoring case/whitespace',
        () async {
      await _entityRepo.createSupplier(name: 'Ali Traders');
      await _entityRepo.createSupplier(name: '  ali   traders ');
      await _entityRepo.createSupplier(name: 'Bilal Steel');
      final groups = await _entityRepo.duplicateSupplierGroups();
      expect(groups, hasLength(1));
      expect(groups.first, hasLength(2));
      expect(groups.first.first.name, 'Ali Traders',
          reason: 'group is ordered oldest-first');
    });

    test('merge re-points ledger onto the kept supplier and archives the rest',
        () async {
      final keep = (await _entityRepo.createSupplier(name: 'Ali Traders')).id;
      final dup = (await _entityRepo.createSupplier(name: 'ali traders')).id;
      final pId = await _project('Site', budget: 1000000);
      // Credit purchases booked against BOTH duplicate rows.
      await _ledgerRepo.postMaterialBuy(
          amount: 30000, projectId: pId, supplierId: keep);
      await _ledgerRepo.postMaterialBuy(
          amount: 20000, projectId: pId, supplierId: dup);

      await _entityRepo.mergeSuppliers(keepId: keep, duplicateIds: [keep, dup]);

      // Balances consolidate onto the kept supplier; the duplicate empties.
      expect(await _ledgerRepo.supplierPayableBalance(keep), 50000,
          reason: 'both credits now owed to the one kept supplier');
      expect(await _ledgerRepo.supplierPayableBalance(dup), 0,
          reason: 'the duplicate has no ledger rows left');

      // The duplicate is archived; the kept one stays active.
      final active = await _entityRepo.suppliers();
      expect(active.map((s) => s.id), contains(keep));
      expect(active.map((s) => s.id), isNot(contains(dup)));
      expect(await _entityRepo.duplicateSupplierGroups(), isEmpty,
          reason: 'no duplicates remain after the merge');
    });
  });
}
