import 'package:bismillah_constructions/shared/data/models/material_item.dart'
    show resolveMaterialLabel;

/// A single material purchase event contributing to rate escalation.
class MaterialEscalationPurchase {
  final String id;
  final DateTime date;
  final String? supplierId;
  final String? supplierName;
  final double quantity;
  final double rate;
  final double totalCost;
  final double baselineRate;

  const MaterialEscalationPurchase({
    required this.id,
    required this.date,
    this.supplierId,
    this.supplierName,
    required this.quantity,
    required this.rate,
    required this.totalCost,
    required this.baselineRate,
  });

  /// Rate increase per unit over the baseline.
  double get rateDelta => (rate - baselineRate).clamp(0.0, double.infinity);

  /// Extra cost extra borne due to rate inflation for this purchase.
  double get extraCost => quantity * rateDelta;
}

/// Inflation and price escalation summary for a single material category on a project.
class MaterialEscalationItem {
  final String materialType;
  final String unit;
  final double baselineRate;
  final double latestRate;
  final double maxRate;
  final double totalQuantity;
  final double totalActualCost;
  final List<MaterialEscalationPurchase> purchases;

  const MaterialEscalationItem({
    required this.materialType,
    required this.unit,
    required this.baselineRate,
    required this.latestRate,
    required this.maxRate,
    required this.totalQuantity,
    required this.totalActualCost,
    required this.purchases,
  });

  String get materialLabel => resolveMaterialLabel(materialType);

  /// Expected cost if purchased at baseline rate.
  double get totalBaselineCost => totalQuantity * baselineRate;

  /// Total extra amount claimable from the client for this material.
  double get escalationClaim =>
      purchases.fold(0.0, (sum, p) => sum + p.extraCost);

  /// Percentage increase between latest rate and baseline rate.
  double get percentageIncrease => baselineRate <= 0
      ? 0.0
      : ((latestRate - baselineRate) / baselineRate) * 100;
}

/// Project-level material price escalation summary for billing clients.
class ProjectEscalationSummary {
  final String projectId;
  final String projectName;
  final String? clientName;
  final String? clientWhatsApp;
  final List<MaterialEscalationItem> items;

  const ProjectEscalationSummary({
    required this.projectId,
    required this.projectName,
    this.clientName,
    this.clientWhatsApp,
    required this.items,
  });

  /// Total actual material cost spent on this project.
  double get totalActualCost =>
      items.fold(0.0, (sum, item) => sum + item.totalActualCost);

  /// Total expected cost at initial baseline rates.
  double get totalBaselineCost =>
      items.fold(0.0, (sum, item) => sum + item.totalBaselineCost);

  /// Overall extra inflation surcharge claimable from the project client.
  double get totalEscalationClaim =>
      items.fold(0.0, (sum, item) => sum + item.escalationClaim);

  /// Total number of purchase transactions analyzed.
  int get purchaseCount =>
      items.fold(0, (sum, item) => sum + item.purchases.length);
}
