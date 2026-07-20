/// User-defined labour category (Mason, Electrician, Plumber, etc.).
///
/// Stored in the `labour_types` table and used by the transaction form to
/// pre-fill context and by the wage ledger to categorise activity by skill.
class LabourTypeDef {
  final String id;

  /// Display name shown in pickers and ledger rows (e.g. "Mason").
  final String name;

  /// Optional free-text skill summary (e.g. "Brickwork, plastering, finishing").
  final String? description;

  /// Typical daily wage for this category — surfaced as a hint in the
  /// amount field so the user doesn't have to recall the rate every time.
  final double? defaultDailyRate;

  final DateTime createdAt;

  const LabourTypeDef({
    required this.id,
    required this.name,
    this.description,
    this.defaultDailyRate,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        'default_daily_rate': defaultDailyRate,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory LabourTypeDef.fromMap(Map<String, Object?> m) => LabourTypeDef(
        id: m['id'] as String,
        name: m['name'] as String,
        description: m['description'] as String?,
        defaultDailyRate: (m['default_daily_rate'] as num?)?.toDouble(),
        createdAt: DateTime.parse(m['created_at'] as String),
      );
}
