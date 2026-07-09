import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/journal_entry.dart';
import '../data/repositories/ledger_repository.dart';
import 'db_providers.dart';

final recentEntriesProvider = FutureProvider<List<JournalEntry>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  return repo.recentEntries(limit: 100);
});

final allEntriesProvider = FutureProvider<List<JournalEntry>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  return repo.allEntries();
});

final allEntriesIncludingDeletedProvider =
    FutureProvider<List<JournalEntry>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  return repo.allEntries(includeDeleted: true);
});

final overallDailySpendProvider =
    FutureProvider<List<DailySpend>>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  return repo.overallDailySpend(daysBack: 7);
});

