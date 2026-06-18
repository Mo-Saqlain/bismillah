// Result classes returned by [LedgerRepository] methods. Kept as a
// `part of` so callers continue to import the single
// `ledger_repository.dart` file and get every related type in one go.
part of 'ledger_repository.dart';

class MonthlyCashFlow {
  final DateTime month;
  final Map<String, double> perAccount;
  const MonthlyCashFlow({required this.month, required this.perAccount});
  double get total => perAccount.values.fold(0, (a, b) => a + b);
}

/// One month of recognized P&L for the Monthly P&L Trend report.
///
/// Each month is the delta of two cumulative [LedgerRepository.incomeFigures]
/// snapshots at the month-end boundaries — see [LedgerRepository.monthlyIncome]
/// for why per-month windows don't work for PoC cost-recovery. The
/// cumulative loss provision is excluded here: it is a forward-looking
/// point-in-time figure, not a monthly flow, and would otherwise
/// double-count if it shifted between months.
class MonthlyIncome {
  final DateTime month;

  /// Recognized contract revenue + service fees earned in the month.
  final double income;
  final double materialCosts;
  final double labourCosts;
  final double personalDraw;

  const MonthlyIncome({
    required this.month,
    required this.income,
    required this.materialCosts,
    required this.labourCosts,
    required this.personalDraw,
  });

  double get costs => materialCosts + labourCosts + personalDraw;
  double get netProfit => income - costs;
}

/// Result of [LedgerRepository.incomeFigures]. Single source of truth for
/// every "what's our P&L?" surface (Income Statement, dashboard Net Profit).
class IncomeFigures {
  /// Recognized contract revenue from With-Material projects, computed via
  /// cost-recovery PoC for active jobs and full contract recognition for
  /// closed jobs.
  final double wmRevenue;
  final double serviceFees;
  final double matCosts;
  final double labCosts;
  final double personalDraw;

  /// Customer money received but not yet earned — sits as a liability.
  final double lrDeposit;
  final double wmDeposit;

  /// Sum of (costs - budget) across every project where costs exceeded
  /// budget. Recognized as an immediate cost line per FASB/IFRS loss
  /// provision rules.
  final double lossProvision;

  /// Projects whose cost-to-date is ≥ 80% of budget. Sorted with already-
  /// over-budget jobs first, then by % consumed descending.
  final List<ProjectAtRisk> projectsAtRisk;

  const IncomeFigures({
    required this.wmRevenue,
    required this.serviceFees,
    required this.matCosts,
    required this.labCosts,
    required this.personalDraw,
    required this.lrDeposit,
    required this.wmDeposit,
    required this.lossProvision,
    required this.projectsAtRisk,
  });

  double get totalIncome => wmRevenue + serviceFees;
  double get totalCosts => matCosts + labCosts + personalDraw + lossProvision;
  double get netProfit => totalIncome - totalCosts;
  double get totalDeposit => lrDeposit + wmDeposit;
}

/// One project's risk snapshot for the dashboard's "Projects at Risk" panel.
class ProjectAtRisk {
  final String projectId;
  final String projectName;
  final double budget;
  final double costsToDate;

  /// 0..100+ — values above 100 mean already over budget.
  final double pctConsumed;
  final bool isOverBudget;

  const ProjectAtRisk({
    required this.projectId,
    required this.projectName,
    required this.budget,
    required this.costsToDate,
    required this.pctConsumed,
    required this.isOverBudget,
  });
}

/// Indirect-method cash flow summary across every cash-like account.
///
/// All `*flow` and `*Outflow` numbers are stored as positive values;
/// the sign is implicit from the field name. `netChange` walks
/// opening cash → closing cash through the bucketed activity totals.
///
/// The high-level fields (`operatingInflow`, `operatingOutflow`,
/// `financingOutflow`) are sums of the per-category breakdown fields —
/// they're kept so older callers don't have to change, but the
/// statement screen now renders the breakdown for a more useful report.
class CashFlowSummary {
  /// Cash position at the moment the period opened (sum of all cash-like
  /// account balances right before `from`). Zero when no `from` is set.
  final double openingCash;

  /// Aggregate operating inflow = projectInflow + serviceFeeInflow.
  final double operatingInflow;
  /// Aggregate operating outflow = materialOutflow + labourOutflow +
  /// supplierPayOutflow.
  final double operatingOutflow;
  final double financingOutflow;

  /// Catch-all for cash legs whose sibling didn't land in any of the
  /// canonical buckets — e.g. legacy data, manual journal corrections.
  final double otherNet;

  // ── Per-category breakdown ──────────────────────────────────────────
  /// Cash received against Project Revenue (`postReceiveFromProject`).
  final double projectInflow;
  /// Cash received against Service Fee Income (`postServiceFee` —
  /// labour-rate one-off fee receipts).
  final double serviceFeeInflow;
  /// Cash paid out directly against Material Costs (counter purchases).
  final double materialOutflow;
  /// Cash paid out directly against Labour Costs (`postLabourPayment`
  /// when no outstanding wage credit, plus the excess leg when the
  /// payment is larger than what was owed).
  final double labourOutflow;
  /// Cash paid out settling supplier payables (`postSupplierPay` and the
  /// smart-settle leg of labour payment).
  final double supplierPayOutflow;
  /// Cash paid out as Personal / Owner Draw.
  final double personalDrawOutflow;
  /// Bank/wallet opening-balance cash recorded against Owner's Equity,
  /// split into "money came in" vs "money was drawn against equity".
  final double equityInflow;
  final double equityOutflow;

  const CashFlowSummary({
    required this.openingCash,
    required this.operatingInflow,
    required this.operatingOutflow,
    required this.financingOutflow,
    required this.otherNet,
    this.projectInflow = 0,
    this.serviceFeeInflow = 0,
    this.materialOutflow = 0,
    this.labourOutflow = 0,
    this.supplierPayOutflow = 0,
    this.personalDrawOutflow = 0,
    this.equityInflow = 0,
    this.equityOutflow = 0,
  });

  static const empty = CashFlowSummary(
    openingCash: 0,
    operatingInflow: 0,
    operatingOutflow: 0,
    financingOutflow: 0,
    otherNet: 0,
  );

  double get netOperating => operatingInflow - operatingOutflow;
  double get netFinancing => -financingOutflow;
  double get netChange => netOperating + netFinancing + otherNet;
  double get closingCash => openingCash + netChange;
}

class ProjectBva {
  /// Keyed by the human-readable material label (e.g. "Cement"). User-defined
  /// types appear here verbatim; legacy enum-name rows are normalized via
  /// [resolveMaterialLabel].
  final Map<String, double> materialByType;
  final double otherMaterial;
  final double labour;
  const ProjectBva({
    required this.materialByType,
    required this.otherMaterial,
    required this.labour,
  });
  double get totalMaterial =>
      materialByType.values.fold<double>(0, (a, b) => a + b) + otherMaterial;
  double get totalSpend => totalMaterial + labour;
}

class PricePoint {
  final DateTime date;
  final double rate;
  const PricePoint({required this.date, required this.rate});
}

class DailySpend {
  final DateTime date;
  final double amount;
  const DailySpend({required this.date, required this.amount});
}

class SupplierSpend {
  final String supplierId;
  final double total;
  const SupplierSpend({required this.supplierId, required this.total});
}

class _OpenInvoice {
  _OpenInvoice({required this.date, required this.remaining});
  final DateTime date;
  double remaining;
}

class AgingLine {
  final String partyId;
  final double bucket0_30;
  final double bucket31_60;
  final double bucket61_90;
  final double bucket90Plus;
  const AgingLine({
    required this.partyId,
    required this.bucket0_30,
    required this.bucket31_60,
    required this.bucket61_90,
    required this.bucket90Plus,
  });
  double get total => bucket0_30 + bucket31_60 + bucket61_90 + bucket90Plus;
}

class AgingReport {
  final DateTime asOf;
  final List<AgingLine> lines;
  const AgingReport({required this.asOf, required this.lines});

  double get total0_30 => lines.fold(0, (s, l) => s + l.bucket0_30);
  double get total31_60 => lines.fold(0, (s, l) => s + l.bucket31_60);
  double get total61_90 => lines.fold(0, (s, l) => s + l.bucket61_90);
  double get total90Plus => lines.fold(0, (s, l) => s + l.bucket90Plus);
  double get grandTotal => total0_30 + total31_60 + total61_90 + total90Plus;
}

/// Settlement snapshot returned by [LedgerRepository.labourRateCloseSummary].
///
/// Sign convention on [netToSettle]:
///   * Positive → contractor is holding the customer's surplus → refund it.
///   * Negative → spending overran customer's deposits → customer owes us
///     this amount (deficit + service fee, packed into one number).
class LabourRateClose {
  final double customerPaid;
  final double totalSpent;
  final double feePercent;
  final double serviceFee;
  final double netToSettle;

  const LabourRateClose({
    required this.customerPaid,
    required this.totalSpent,
    required this.feePercent,
    required this.serviceFee,
    required this.netToSettle,
  });

  /// Amount the contractor has to refund (0 when the customer underpaid).
  double get refundToCustomer => netToSettle > 0 ? netToSettle : 0;

  /// Amount the customer still owes (0 when overpaid). Already includes
  /// the service fee in the deficit case.
  double get customerOwesUs => netToSettle < 0 ? -netToSettle : 0;
}

/// One-screen aggregate consumed by the Site Snapshot screen and the
/// Project Closure Assistant. Everything here is derived from the ledger
/// + the project row — no separate state, no caching.
class ProjectSnapshot {
  final String projectId;
  final String? model;
  final double budget;
  final double received;
  final double spent;
  final double materialCosts;
  final double labourCosts;
  final double serviceFeeBooked;
  final double supplierPayables;

  /// Money received but not yet earned (PoC cost-recovery).
  final double customerDeposit;

  /// Profit recognized so far: revenue minus spend minus deposit liability.
  final double realizedProfit;

  /// Owner-entered manual completion estimate (0..100). 0 means "no
  /// estimate yet" and the snapshot falls back to budget headroom.
  final int completionPercent;

  /// Forecast cost to reach 100% completion. When `completionPercent` is
  /// 0, equals `max(budget − spent, 0)`. When >0, uses the linear
  /// extrapolation `spent / pct × (100 − pct)`.
  final double projectedRemainingCost;

  /// Forecast remaining customer receivable: `max(budget − received, 0)`.
  final double projectedReceivable;

  /// `projectedRemainingCost − projectedReceivable`. Positive means cash
  /// stress ahead (you'll spend more than you have left to collect);
  /// negative means surplus.
  final double projectedCashGap;

  /// Projected bottom-line profit at close. For WM:
  /// `budget − (spent + projectedRemainingCost)`. For LR or budget=0
  /// projects: `received − projected total cost`.
  final double projectedFinalProfit;

  const ProjectSnapshot({
    required this.projectId,
    required this.model,
    required this.budget,
    required this.received,
    required this.spent,
    required this.materialCosts,
    required this.labourCosts,
    required this.serviceFeeBooked,
    required this.supplierPayables,
    required this.customerDeposit,
    required this.realizedProfit,
    required this.completionPercent,
    required this.projectedRemainingCost,
    required this.projectedReceivable,
    required this.projectedCashGap,
    required this.projectedFinalProfit,
  });

  /// Risk band based on how much of the budget has been consumed and
  /// whether the project is already over-budget. Drives the snapshot
  /// card's color treatment.
  ///   * `green`  — under 80% of budget consumed.
  ///   * `amber`  — between 80% and 100%.
  ///   * `red`    — over 100% of budget OR projected to overrun.
  String get riskBand {
    if (budget <= 0) return 'green';
    final pctConsumed = spent / budget * 100;
    if (pctConsumed >= 100) return 'red';
    final projectedTotal = spent + projectedRemainingCost;
    if (projectedTotal > budget * 1.05) return 'red';
    if (pctConsumed >= 80) return 'amber';
    return 'green';
  }

  /// Cost-consumption percentage (0..100+). Used by progress bars.
  double get pctOfBudgetConsumed =>
      budget > 0 ? spent / budget * 100 : 0;
}

class ProjectReconciliation {
  /// Total received from the project (credits to PROJECT_REV for this project).
  final double projectInflow;

  /// Sum of debits to SUPPLIER_PAY for this project.
  final double supplierPaid;

  /// Outstanding payables (credits − debits) on SUPPLIER_PAY for this project.
  final double supplierPayables;

  const ProjectReconciliation({
    required this.projectInflow,
    required this.supplierPaid,
    required this.supplierPayables,
  });

  /// New rule (post-customer-removal): reconciled when no payables remain.
  /// The cash received minus costs incurred is the project's savings/profit
  /// and does not need to balance to zero.
  bool get isBalanced => supplierPayables.abs() < 0.01;

  /// Net cash position from project = inflow − supplier obligations (paid + open).
  double get savings => projectInflow - (supplierPaid + supplierPayables);
}
