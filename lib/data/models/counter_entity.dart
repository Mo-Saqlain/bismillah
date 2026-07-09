import '../../core/constants.dart';

class CounterEntity {
  final String id;
  final String name;
  final CounterEntityType type;
  final double amount;
  final DateTime createdAt;

  const CounterEntity({
    required this.id,
    required this.name,
    required this.type,
    required this.amount,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'type': type.db,
        'amount': amount,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory CounterEntity.fromMap(Map<String, Object?> m) => CounterEntity(
        id: m['id'] as String,
        name: m['name'] as String,
        type: CounterEntityTypeX.fromDb(m['type'] as String),
        amount: (m['amount'] as num).toDouble(),
        createdAt: DateTime.parse(m['created_at'] as String),
      );
}
