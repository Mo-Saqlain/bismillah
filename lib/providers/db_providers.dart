import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../data/db/local_db.dart';
import '../data/repositories/entity_repository.dart';
import '../data/repositories/ledger_repository.dart';

/// Bumped after every successful ledger write so dependent providers
/// invalidate and re-query. Watched by every read-side provider that
/// shows derived numbers on the dashboard / reports.
final ledgerVersionProvider = StateProvider<int>((_) => 0);

void bumpLedger(WidgetRef ref) {
  ref.read(ledgerVersionProvider.notifier).update((v) => v + 1);
}

final dbProvider = FutureProvider<Database>((ref) async {
  return LocalDb.instance.open();
});

final ledgerRepoProvider = FutureProvider<LedgerRepository>((ref) async {
  final db = await ref.watch(dbProvider.future);
  return LedgerRepository(db);
});

final entityRepoProvider = FutureProvider<EntityRepository>((ref) async {
  final db = await ref.watch(dbProvider.future);
  return EntityRepository(db);
});
