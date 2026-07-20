import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/constants.dart';
import 'package:bismillah_constructions/shared/data/models/bank.dart';
import 'package:bismillah_constructions/shared/data/models/follow_up.dart';
import 'package:bismillah_constructions/shared/data/models/labour_type_def.dart';
import 'package:bismillah_constructions/shared/data/models/material_type_def.dart';
import 'package:bismillah_constructions/shared/data/models/note.dart';
import 'package:bismillah_constructions/shared/data/models/party.dart';
import 'package:bismillah_constructions/shared/data/models/project.dart';
import 'package:bismillah_constructions/shared/data/repositories/ledger_repository.dart';
import 'package:bismillah_constructions/shared/providers/db_providers.dart';

final projectsProvider = FutureProvider<List<Project>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(entityRepoProvider.future);
  return repo.projects();
});

final activeProjectsProvider = FutureProvider<List<Project>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(entityRepoProvider.future);
  return repo.projects(activeOnly: true);
});

final archivedProjectsProvider = FutureProvider<List<Project>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(entityRepoProvider.future);
  return repo.archivedProjects();
});

final suppliersProvider = FutureProvider<List<Party>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(entityRepoProvider.future);
  return repo.suppliers();
});

final archivedSuppliersProvider = FutureProvider<List<Party>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(entityRepoProvider.future);
  return repo.archivedSuppliers();
});

final banksProvider = FutureProvider<List<Bank>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(entityRepoProvider.future);
  return repo.banks();
});

final archivedBanksProvider = FutureProvider<List<Bank>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(entityRepoProvider.future);
  return repo.archivedBanks();
});

/// Cash-like accounts for the transaction form / dashboard.
/// Combines the system Cash + Supervisor Float with every user-defined bank.
final cashLikeAccountsProvider =
    FutureProvider<List<Account>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final banks = await ref.watch(banksProvider.future);
  return [
    ...Accounts.systemCashLike,
    ...banks.map(
      (b) => Account(b.id, b.name, AccountType.asset),
    ),
  ];
});

/// User-defined material categories. Bumping [ledgerVersionProvider]
/// after add/delete refreshes the dropdown everywhere that watches this
/// list.
final materialTypesProvider =
    FutureProvider<List<MaterialTypeDef>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(entityRepoProvider.future);
  return repo.materialTypes();
});

final labourTypesProvider =
    FutureProvider<List<LabourTypeDef>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(entityRepoProvider.future);
  return repo.labourTypes();
});

// ── v14: Notes ─────────────────────────────────────────────────────────

/// Notes attached to one entity (project / supplier). The family key is a
/// `(type, entityId)` record so the same provider serves both surfaces.
final notesForProvider = FutureProvider.family<List<Note>,
    ({NoteEntityType type, String entityId})>((ref, key) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(entityRepoProvider.future);
  return repo.notesFor(key.type, key.entityId);
});

// ── v14: Follow-Ups ────────────────────────────────────────────────────

final pendingFollowUpsProvider = FutureProvider<List<FollowUp>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(entityRepoProvider.future);
  return repo.pendingFollowUps();
});

final archivedFollowUpsProvider = FutureProvider<List<FollowUp>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(entityRepoProvider.future);
  return repo.archivedFollowUps();
});

// ── v14: Project Snapshot ──────────────────────────────────────────────

final projectSnapshotProvider =
    FutureProvider.family<ProjectSnapshot, String>((ref, projectId) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  return repo.projectSnapshot(projectId);
});
