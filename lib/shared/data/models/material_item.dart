import 'package:bismillah_constructions/shared/core/constants.dart';

/// One row of the material inventory ledger.
///
/// `materialType` was originally a fixed enum (brick/cement/sarya/finishing/
/// other). It is now a free-form String so users can define their own
/// categories from Settings → Material Types. Legacy rows that stored the
/// enum's `name` (lowercase) are normalized into a friendly label by
/// [resolveMaterialLabel].
class MaterialItem {
  final String id;
  final String projectId;
  /// Nullable as of schema v12: counter-purchase rows aren't attached to
  /// a supplier (paid on the spot from cash / bank).
  final String? supplierId;
  final String? transactionId;
  final String materialType;
  final MaterialUnit unit;
  /// Nullable as of schema v17: a material buy may be logged without a
  /// quantity (the cost lives in the memo). Rows with a null quantity carry
  /// a null [rate] too and are excluded from the Material Price Trend — the
  /// trend only plots purchases where a real per-unit rate exists.
  final double? quantity;
  final double? rate;
  final double totalCost;
  final MaterialTxnType txnType;
  final DateTime createdAt;

  const MaterialItem({
    required this.id,
    required this.projectId,
    this.supplierId,
    this.transactionId,
    required this.materialType,
    required this.unit,
    required this.quantity,
    required this.rate,
    required this.totalCost,
    required this.txnType,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'project_id': projectId,
        'supplier_id': supplierId,
        'transaction_id': transactionId,
        'material_type': materialType,
        'unit': unit.db,
        'quantity': quantity,
        'rate': rate,
        'total_cost': totalCost,
        'txn_type': txnType.db,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory MaterialItem.fromMap(Map<String, Object?> m) => MaterialItem(
        id: m['id'] as String,
        projectId: m['project_id'] as String,
        supplierId: m['supplier_id'] as String?,
        transactionId: m['transaction_id'] as String?,
        materialType: resolveMaterialLabel(m['material_type'] as String),
        unit: MaterialUnitX.fromDb(m['unit'] as String),
        quantity: (m['quantity'] as num?)?.toDouble(),
        rate: (m['rate'] as num?)?.toDouble(),
        totalCost: (m['total_cost'] as num).toDouble(),
        txnType: MaterialTxnTypeX.fromDb(m['txn_type'] as String),
        createdAt: DateTime.parse(m['created_at'] as String),
      );
}

/// Maps legacy lowercase enum names ("brick", "cement", ...) to the
/// human-readable labels now stored in `material_types.name`. Anything else
/// is returned verbatim — that is the user-defined label.
String resolveMaterialLabel(String stored) {
  switch (stored) {
    case 'brick':
      return 'Brick';
    case 'cement':
      return 'Cement';
    case 'sarya':
      return 'Sarya (Steel)';
    case 'finishing':
      return 'Finishing';
    case 'other':
      return 'Other';
    default:
      return stored;
  }
}
