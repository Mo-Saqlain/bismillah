import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_summary.dart';
import 'db_providers.dart';

/// How many days of current liquid cash the business can sustain at the
/// active-day average daily burn rate. Null means no spending history yet.
class CashRunway {
  final double? days;
  final double avgDailyExpense;
  const CashRunway({required this.days, required this.avgDailyExpense});

  bool get isGreen => days != null && days! >= 30;
  bool get isYellow => days != null && days! >= 15 && days! < 30;
  bool get isRed => days != null && days! < 15;
}

final cashRunwayProvider = FutureProvider<CashRunway>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  final avgDaily = await repo.averageDailyExpense();
  if (avgDaily <= 0) return const CashRunway(days: null, avgDailyExpense: 0);
  final summary = await ref.watch(accountSummaryProvider.future);
  return CashRunway(
    days: summary.liquidCash / avgDaily,
    avgDailyExpense: avgDaily,
  );
});
