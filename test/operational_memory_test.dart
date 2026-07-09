// White-box tests for the v14 operational-memory layer: notes,
// recovery follow-ups, manual completion %, and the ProjectSnapshot
// aggregator that powers the Site Snapshot screen + Closure Assistant.
// All tests drive the real SQLite engine via sqflite_common_ffi — no
// mocks — so the production migration code is exercised on every run.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bismillah_constructions/core/constants.dart';
import 'package:bismillah_constructions/data/db/local_db.dart';
import 'package:bismillah_constructions/data/models/follow_up.dart';
import 'package:bismillah_constructions/data/models/note.dart';
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

Future<String> _project(String name,
    {ProjectModel model = ProjectModel.withMaterial, double? budget}) async {
  final p = await _entityRepo.createProject(
    name: name,
    model: model,
    budget: budget,
  );
  return p.id;
}

void main() {
  setUpAll(() => sqfliteFfiInit());
  setUp(_resetDb);
  tearDown(() async => _db.close());

  // ───────────────────────────────────────────────────────────────────────
  //  Notes
  // ───────────────────────────────────────────────────────────────────────

  group('Notes', () {
    test('add → list → soft-delete leaves the row in place but hidden',
        () async {
      final sId = await _supplier('Steelco');
      final note = await _entityRepo.addNote(
        type: NoteEntityType.supplier,
        entityId: sId,
        body: 'Slow on settlements; chase weekly.',
      );

      final visible =
          await _entityRepo.notesFor(NoteEntityType.supplier, sId);
      expect(visible, hasLength(1));
      expect(visible.first.body, contains('Slow on settlements'));

      await _entityRepo.deleteNote(note.id);
      final after = await _entityRepo.notesFor(NoteEntityType.supplier, sId);
      expect(after, isEmpty, reason: 'soft-deleted notes are filtered out');

      // But the row is still on disk, so a future "trash" surface could
      // restore it. We poke the DB directly to confirm.
      final raw = await _db
          .query('notes', where: 'id = ?', whereArgs: [note.id]);
      expect(raw, hasLength(1));
      expect(raw.first['is_deleted'], 1);
    });

    test('pinned notes float above unpinned, then newest-first', () async {
      final pId = await _project('Site A', budget: 1000000);
      // Insert in a deterministic, time-ordered sequence so the "newest
      // first" assertion is robust.
      final older = await _entityRepo.addNote(
        type: NoteEntityType.project,
        entityId: pId,
        body: 'Older unpinned note',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await _entityRepo.addNote(
        type: NoteEntityType.project,
        entityId: pId,
        body: 'Newer unpinned note',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final pinned = await _entityRepo.addNote(
        type: NoteEntityType.project,
        entityId: pId,
        body: 'Important — pinned',
        pinned: true,
      );

      final notes =
          await _entityRepo.notesFor(NoteEntityType.project, pId);
      expect(notes, hasLength(3));
      expect(notes.first.id, pinned.id,
          reason: 'pinned notes must come first');
      // The remaining two are unpinned, newest-first.
      expect(notes[1].body, contains('Newer unpinned'));
      expect(notes[2].id, older.id);
    });

    test('searchNotes returns case-insensitive substring matches', () async {
      final pId = await _project('Site A', budget: 1000000);
      await _entityRepo.addNote(
        type: NoteEntityType.project,
        entityId: pId,
        body: 'Cement delivery delayed',
      );
      await _entityRepo.addNote(
        type: NoteEntityType.project,
        entityId: pId,
        body: 'Mason team did good work',
      );

      final hits = await _entityRepo.searchNotes('CEMENT');
      expect(hits, hasLength(1));
      expect(hits.first.body, contains('Cement'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  //  Follow-ups
  // ───────────────────────────────────────────────────────────────────────

  group('Follow-ups', () {
    test('overdue detection uses expectedDate + status', () async {
      final pId = await _project('Site A', budget: 1000000);
      final past = DateTime.now().subtract(const Duration(days: 3));
      final future = DateTime.now().add(const Duration(days: 5));

      final overdue = await _entityRepo.addFollowUp(
        title: 'Customer to clear Rs 500k',
        projectId: pId,
        expectedDate: past,
        priority: FollowUpPriority.high,
      );
      await _entityRepo.addFollowUp(
        title: 'Supplier visit scheduled',
        projectId: pId,
        expectedDate: future,
      );

      final overdueList = await _entityRepo.overdueFollowUps();
      expect(overdueList, hasLength(1));
      expect(overdueList.first.id, overdue.id);

      // Resolving the overdue one removes it from the overdue list.
      await _entityRepo.resolveFollowUp(overdue.id);
      final after = await _entityRepo.overdueFollowUps();
      expect(after, isEmpty);
    });

    test('pending list sorts overdue-first, then by priority, then by date',
        () async {
      final pId = await _project('Site A', budget: 1000000);
      final past = DateTime.now().subtract(const Duration(days: 1));
      final futureSoon = DateTime.now().add(const Duration(days: 3));
      final futureLater = DateTime.now().add(const Duration(days: 10));

      final lowOverdue = await _entityRepo.addFollowUp(
          title: 'Low overdue',
          projectId: pId,
          expectedDate: past,
          priority: FollowUpPriority.low);
      final highSoon = await _entityRepo.addFollowUp(
          title: 'High soon',
          projectId: pId,
          expectedDate: futureSoon,
          priority: FollowUpPriority.high);
      final mediumLater = await _entityRepo.addFollowUp(
          title: 'Medium later',
          projectId: pId,
          expectedDate: futureLater,
          priority: FollowUpPriority.medium);

      final pending = await _entityRepo.pendingFollowUps();
      expect(pending.map((e) => e.id),
          [lowOverdue.id, highSoon.id, mediumLater.id],
          reason: 'overdue wins regardless of priority; '
              'within not-overdue, higher priority comes first');
    });

    test('resolve / reopen toggle preserves history', () async {
      final f = await _entityRepo.addFollowUp(
        title: 'Pay Asif Rs 100k',
        priority: FollowUpPriority.medium,
      );
      await _entityRepo.resolveFollowUp(f.id);

      final pending = await _entityRepo.pendingFollowUps();
      expect(pending, isEmpty);

      final archived = await _entityRepo.archivedFollowUps();
      expect(archived, hasLength(1));
      expect(archived.first.status, FollowUpStatus.resolved);
      expect(archived.first.resolvedAt, isNotNull);

      await _entityRepo.reopenFollowUp(f.id);
      final pendingAgain = await _entityRepo.pendingFollowUps();
      expect(pendingAgain, hasLength(1));
      expect(pendingAgain.first.status, FollowUpStatus.pending);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  //  Manual completion %
  // ───────────────────────────────────────────────────────────────────────

  group('Project completion %', () {
    test('updateProjectCompletion clamps to 0..100', () async {
      final pId = await _project('Site A', budget: 1000000);

      await _entityRepo.updateProjectCompletion(pId, 137);
      final p1 = await _entityRepo.project(pId);
      expect(p1!.completionPercent, 100,
          reason: 'over-100 values clamp down to 100');

      await _entityRepo.updateProjectCompletion(pId, -25);
      final p2 = await _entityRepo.project(pId);
      expect(p2!.completionPercent, 0,
          reason: 'negative values clamp up to 0');

      await _entityRepo.updateProjectCompletion(pId, 60);
      final p3 = await _entityRepo.project(pId);
      expect(p3!.completionPercent, 60);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  //  Project Snapshot (powers Site Snapshot + Closure Assistant)
  // ───────────────────────────────────────────────────────────────────────

  group('ProjectSnapshot', () {
    test('forecast uses completion% to extrapolate remaining cost',
        () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Site A', budget: 1000000);

      // Spent 300k so far, customer paid 200k, owner says 30% done.
      await _ledgerRepo.postMaterialBuy(
          amount: 300000, projectId: pId, supplierId: sId);
      await _ledgerRepo.postReceiveFromProject(
          amount: 200000, projectId: pId, receivedInto: Accounts.cash);
      await _entityRepo.updateProjectCompletion(pId, 30);

      final snap = await _ledgerRepo.projectSnapshot(pId);
      expect(snap.spent, 300000);
      expect(snap.received, 200000);
      // 300k / 30% × 70% = 700k still to spend.
      expect(snap.projectedRemainingCost, closeTo(700000, 0.01));
      // Receivable still expected = 1m − 200k = 800k.
      expect(snap.projectedReceivable, closeTo(800000, 0.01));
      // Projected final cost = 1m, budget = 1m → profit 0 at close.
      expect(snap.projectedFinalProfit, closeTo(0, 0.01));
    });

    test('riskBand flips to red when projected cost exceeds budget',
        () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Doomed', budget: 1000000);

      // Spent 600k at 40% complete → projected total 1.5m. Over budget by 50%.
      await _ledgerRepo.postMaterialBuy(
          amount: 600000, projectId: pId, supplierId: sId);
      await _entityRepo.updateProjectCompletion(pId, 40);

      final snap = await _ledgerRepo.projectSnapshot(pId);
      expect(snap.riskBand, 'red');
      // Projected profit at close = budget − projected total = 1m − 1.5m = -500k.
      expect(snap.projectedFinalProfit, closeTo(-500000, 0.01));
    });

    test('customerDeposit equals received − spent under PoC', () async {
      final sId = await _supplier('Steelco');
      final pId = await _project('Prepaid', budget: 1000000);

      // Customer paid 500k upfront, only 100k spent so far.
      await _ledgerRepo.postReceiveFromProject(
          amount: 500000, projectId: pId, receivedInto: Accounts.cash);
      await _ledgerRepo.postMaterialBuy(
          amount: 100000, projectId: pId, supplierId: sId);

      final snap = await _ledgerRepo.projectSnapshot(pId);
      expect(snap.customerDeposit, closeTo(400000, 0.01),
          reason: 'received 500k − spent 100k = 400k cash trapped');
      // Realized profit so far must be zero under cost-recovery PoC.
      expect(snap.realizedProfit, closeTo(0, 0.01));
    });
  });
}
