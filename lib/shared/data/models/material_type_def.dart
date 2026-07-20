import 'dart:convert';

/// Unit-of-measure dimension class for a material category.
///
/// Drives how the material is priced/ordered:
///   * `discrete` — countable units (bricks, tiles, fittings) — usually
///     paired with `Each` or `Pieces`. May carry physical dimensions in
///     [MaterialTypeDef.dims].
///   * `surface`  — surface area (tiles per square foot, paint coverage).
///     [MaterialTypeDef.coverageRate] kicks in here.
///   * `volume`   — volume (concrete in cubic yards, sand in cubic meters).
///   * `weight`   — weight (steel, cement bags, etc.).
enum UomType { discrete, surface, volume, weight }

extension UomTypeX on UomType {
  String get db => name;

  /// Full human-readable label. We deliberately do not abbreviate — the
  /// user prefers "Discrete" / "Surface" / "Volume" / "Weight" everywhere
  /// the type is shown.
  String get label => switch (this) {
        UomType.discrete => 'Discrete',
        UomType.surface => 'Surface',
        UomType.volume => 'Volume',
        UomType.weight => 'Weight',
      };

  /// Suggested unit-of-measure strings for the picker. Spelled out — the
  /// user can still type whatever they like, these are just defaults so
  /// the field isn't blank.
  List<String> get defaultUoms => switch (this) {
        UomType.discrete => const ['Each', 'Pieces'],
        UomType.surface => const ['Square Feet', 'Square Meters'],
        UomType.volume => const ['Cubic Yards', 'Cubic Meters', 'Liters'],
        UomType.weight => const ['Pounds', 'Kilograms', 'Bags', 'Tons'],
      };

  static UomType? fromDb(String? s) {
    if (s == null) return null;
    // Backwards-compat shim: rows written before the v8 → v9 rename used
    // the abbreviated enum names ('disc', 'surf', 'vol', 'wgt'). Map them
    // onto the new spelled-out enum so existing data keeps working.
    const aliases = <String, UomType>{
      'disc': UomType.discrete,
      'surf': UomType.surface,
      'vol': UomType.volume,
      'wgt': UomType.weight,
    };
    if (aliases.containsKey(s)) return aliases[s];
    return UomType.values
        .firstWhere((v) => v.name == s, orElse: () => UomType.discrete);
  }
}

/// Length / Width / Height for [UomType.discrete] items (e.g. a brick is
/// 9"×4.5"×3"). All three are optional — record only what's known.
class MaterialDims {
  final double? length;
  final double? width;
  final double? height;
  final String? unit; // free-form: "in", "cm", etc.

  const MaterialDims({this.length, this.width, this.height, this.unit});

  bool get isEmpty =>
      length == null && width == null && height == null && unit == null;

  Map<String, Object?> toJson() => {
        'l': length,
        'w': width,
        'h': height,
        'u': unit,
      };

  static MaterialDims? fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return MaterialDims(
        length: (m['l'] as num?)?.toDouble(),
        width: (m['w'] as num?)?.toDouble(),
        height: (m['h'] as num?)?.toDouble(),
        unit: m['u'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// User-managed material category. Built-in rows (the original five) cannot
/// be deleted but their label can be renamed; custom rows are fully editable.
///
/// v8 added procurement metadata (UOM class + unit, coverage rate, physical
/// dims). The waste-factor and lead-time fields that briefly lived here were
/// removed by user request — the underlying database columns remain (so old
/// installs upgrade cleanly), they're just no longer surfaced.
class MaterialTypeDef {
  final String id;
  final String name;
  final bool isBuiltin;
  final int sortOrder;
  final UomType? uomType;

  /// Free-form unit string spelled out where possible
  /// ("Each", "Square Feet", "Cubic Yards", "Pounds", "Bags", …).
  /// Not constrained to a fixed enum because every site has its own
  /// conventions.
  final String? uom;

  /// Units required per area, only meaningful for [UomType.surface]
  /// (e.g. 4 tiles per square foot).
  final double? coverageRate;

  /// L/W/H bundle for [UomType.discrete] items.
  final MaterialDims? dims;

  final DateTime createdAt;

  const MaterialTypeDef({
    required this.id,
    required this.name,
    required this.isBuiltin,
    required this.sortOrder,
    required this.createdAt,
    this.uomType,
    this.uom,
    this.coverageRate,
    this.dims,
  });

  MaterialTypeDef copyWith({
    String? name,
    UomType? uomType,
    String? uom,
    double? coverageRate,
    MaterialDims? dims,
  }) =>
      MaterialTypeDef(
        id: id,
        name: name ?? this.name,
        isBuiltin: isBuiltin,
        sortOrder: sortOrder,
        createdAt: createdAt,
        uomType: uomType ?? this.uomType,
        uom: uom ?? this.uom,
        coverageRate: coverageRate ?? this.coverageRate,
        dims: dims ?? this.dims,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'is_builtin': isBuiltin ? 1 : 0,
        'sort_order': sortOrder,
        'uom_typ': uomType?.db,
        'uom': uom,
        'cov_rate': coverageRate,
        'dims':
            (dims == null || dims!.isEmpty) ? null : jsonEncode(dims!.toJson()),
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory MaterialTypeDef.fromMap(Map<String, Object?> m) => MaterialTypeDef(
        id: m['id'] as String,
        name: m['name'] as String,
        isBuiltin: ((m['is_builtin'] as num?)?.toInt() ?? 0) == 1,
        sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
        uomType: UomTypeX.fromDb(m['uom_typ'] as String?),
        uom: m['uom'] as String?,
        coverageRate: (m['cov_rate'] as num?)?.toDouble(),
        dims: MaterialDims.fromJson(m['dims'] as String?),
        createdAt: DateTime.parse(m['created_at'] as String),
      );
}
