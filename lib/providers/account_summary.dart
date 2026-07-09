import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../data/repositories/ledger_repository.dart';
import 'db_providers.dart';
import 'entity_providers.dart';

/// Bundle of every aggregate the dashboard's Treasury card needs in one
/// shot. Computed from [LedgerRepository.incomeFigures] + a handful of
/// account-level balance queries so dashboard, Income Statement and BvA
/// always agree.
class AccountSummary {
  /// System cash (Cash account).
  final double cash;

  /// Per user-defined bank balance, keyed by bank id.
  final Map<String, double> bankBalances;

  /// Outstanding supplier payables (credits − debits).
  final double payables;

  /// Sum of money owed to us by customers (under-funded projects).
  /// Computed via the same FIFO logic as the Aging Receivables report.
  final double projectReceivables;

  /// Sum of advances we are sitting on with our suppliers (we paid more
  /// than we have been billed).
  final double supplierOverpayments;

  final double materialCosts;
  final double labourCosts;

  /// PoC-recognized contract revenue (cost-recovery for active jobs, full
  /// contract on close). NOT raw projectRevenue credits — those would
  /// inflate profit by booking customer deposits as earned income.
  final double revenue;
  final double serviceFeeIncome;
  final double personalDraw;

  /// Sum of (costs - budget) across every project where actual costs
  /// exceeded budget. Recognized as an immediate cost (FASB/IFRS).
  final double lossProvision;

  /// Customer money received but not yet earned — a liability we'd have
  /// to refund / deliver work for. Sum of LR + With-Material deposits.
  final double customerDeposits;

  /// Project-level loss warnings sourced from
  /// [LedgerRepository.incomeFigures].
  final List<ProjectAtRisk> projectsAtRisk;

  final double counterReceivables;
  final double counterPayables;

  const AccountSummary({
    required this.cash,
    required this.bankBalances,
    required this.payables,
    required this.projectReceivables,
    required this.supplierOverpayments,
    required this.materialCosts,
    required this.labourCosts,
    required this.revenue,
    required this.serviceFeeIncome,
    required this.personalDraw,
    required this.lossProvision,
    required this.customerDeposits,
    required this.projectsAtRisk,
    required this.counterReceivables,
    required this.counterPayables,
  });

  /// Total amount owed to us — what the home screen's "Receivables" tile
  /// shows. Combines unpaid project work and supplier overpayments.
  double get totalReceivables => projectReceivables + supplierOverpayments;

  double get totalBanks =>
      bankBalances.values.fold<double>(0, (a, b) => a + b);

  /// Cash + every user-defined bank/wallet.
  double get liquidCash => cash + totalBanks;

  /// Spec section 6: Liquid_Cash − Total_Supplier_Payables.
  double get netLiquidity => liquidCash - payables;

  double get assets => liquidCash + counterReceivables;
  double get liabilities => payables + counterPayables;
  double get netProfit =>
      revenue +
      serviceFeeIncome -
      (materialCosts + labourCosts + personalDraw + lossProvision);
  double get equity => assets - liabilities;

  double get netPosition => counterReceivables - (payables + counterPayables);
  double get totalNetWorth => liquidCash + netPosition;
}

final accountSummaryProvider = FutureProvider<AccountSummary>((ref) async {
  ref.watch(ledgerVersionProvider);
  final repo = await ref.watch(ledgerRepoProvider.future);
  final entityRepo = await ref.watch(entityRepoProvider.future);
  final banks = await ref.watch(banksProvider.future);

  Future<double> dr(String id) => repo.accountBalance(id);
  Future<double> cr(String id) => repo.creditBalance(id);

  final fixed = await Future.wait([
    dr(Accounts.cash.id),
    cr(Accounts.supplierPayables.id),
    dr(Accounts.personalDraw.id),
  ]);

  final bankBalances = <String, double>{
    for (final b in banks) b.id: await dr(b.id),
  };

  final entities = await entityRepo.counterEntities();
  final counterRecv = entities
      .where((e) => e.type == CounterEntityType.receivable)
      .fold<double>(0, (s, e) => s + e.amount);
  final counterPay = entities
      .where((e) => e.type == CounterEntityType.payable)
      .fold<double>(0, (s, e) => s + e.amount);

  // Receivables totals via the FIFO aging logic — same source the Aging
  // Receivables screen uses, so the dashboard tile and the report always
  // agree.
  final receivables = await repo.receivablesTotals();

  // PoC-recognized P&L figures — single source of truth shared with the
  // Income Statement. Avoids fake profit from advance customer payments.
  final income = await repo.incomeFigures();

  return AccountSummary(
    cash: fixed[0],
    bankBalances: bankBalances,
    payables: fixed[1],
    projectReceivables: receivables.projectsOwed,
    supplierOverpayments: receivables.suppliersOverpaid,
    materialCosts: income.matCosts,
    labourCosts: income.labCosts,
    revenue: income.wmRevenue,
    serviceFeeIncome: income.serviceFees,
    personalDraw: fixed[2],
    lossProvision: income.lossProvision,
    customerDeposits: income.totalDeposit,
    projectsAtRisk: income.projectsAtRisk,
    counterReceivables: counterRecv,
    counterPayables: counterPay,
  );
});
