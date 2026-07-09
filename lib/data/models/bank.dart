class Bank {
  final String id;
  final String name;
  final String? accountNo;
  final DateTime createdAt;

  /// 1 = archived (kept for audit, hidden from default lists).
  final int isArchived;
  final DateTime? archivedAt;

  const Bank({
    required this.id,
    required this.name,
    this.accountNo,
    required this.createdAt,
    this.isArchived = 0,
    this.archivedAt,
  });

  bool get archived => isArchived == 1;

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'account_no': accountNo,
        'created_at': createdAt.toUtc().toIso8601String(),
        'is_archived': isArchived,
        'archived_at': archivedAt?.toUtc().toIso8601String(),
      };

  factory Bank.fromMap(Map<String, Object?> m) => Bank(
        id: m['id'] as String,
        name: m['name'] as String,
        accountNo: m['account_no'] as String?,
        createdAt: DateTime.parse(m['created_at'] as String),
        isArchived: (m['is_archived'] as int?) ?? 0,
        archivedAt: m['archived_at'] == null
            ? null
            : DateTime.parse(m['archived_at'] as String),
      );

  Bank copyWith({
    String? name,
    String? accountNo,
    int? isArchived,
    DateTime? archivedAt,
  }) =>
      Bank(
        id: id,
        name: name ?? this.name,
        accountNo: accountNo ?? this.accountNo,
        createdAt: createdAt,
        isArchived: isArchived ?? this.isArchived,
        archivedAt: archivedAt ?? this.archivedAt,
      );
}
