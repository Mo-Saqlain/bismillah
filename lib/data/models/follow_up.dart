enum FollowUpPriority { low, medium, high }

extension FollowUpPriorityX on FollowUpPriority {
  String get db => name;
  String get label => switch (this) {
        FollowUpPriority.low => 'Low',
        FollowUpPriority.medium => 'Medium',
        FollowUpPriority.high => 'High',
      };
  static FollowUpPriority fromDb(String s) =>
      FollowUpPriority.values.firstWhere((v) => v.name == s,
          orElse: () => FollowUpPriority.medium);
}

enum FollowUpStatus { pending, resolved, cancelled }

extension FollowUpStatusX on FollowUpStatus {
  String get db => name;
  String get label => switch (this) {
        FollowUpStatus.pending => 'Pending',
        FollowUpStatus.resolved => 'Resolved',
        FollowUpStatus.cancelled => 'Cancelled',
      };
  static FollowUpStatus fromDb(String s) =>
      FollowUpStatus.values.firstWhere((v) => v.name == s,
          orElse: () => FollowUpStatus.pending);
}

/// Customer recovery / payment-promise tracker. Lightweight: this is
/// forward-looking memory, not an audit record — once resolved, the row
/// stays in place with `resolved_at` set so the history is searchable but
/// `pending` lists stay clean.
class FollowUp {
  final String id;
  final String? projectId;
  final String? supplierId;
  final String title;
  final String? note;
  final DateTime? expectedDate;
  final FollowUpPriority priority;
  final FollowUpStatus status;
  final double? amountEstimate;
  final bool isDeleted;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime? resolvedAt;

  const FollowUp({
    required this.id,
    required this.title,
    required this.priority,
    required this.status,
    required this.createdAt,
    this.projectId,
    this.supplierId,
    this.note,
    this.expectedDate,
    this.amountEstimate,
    this.isDeleted = false,
    this.deletedAt,
    this.resolvedAt,
  });

  /// `true` when there's an [expectedDate] in the past AND the follow-up
  /// is still pending.
  bool isOverdue([DateTime? now]) {
    if (status != FollowUpStatus.pending) return false;
    final d = expectedDate;
    if (d == null) return false;
    return d.isBefore(now ?? DateTime.now());
  }

  FollowUp copyWith({
    String? title,
    String? note,
    DateTime? expectedDate,
    FollowUpPriority? priority,
    FollowUpStatus? status,
    double? amountEstimate,
    bool? isDeleted,
    DateTime? deletedAt,
    DateTime? resolvedAt,
  }) =>
      FollowUp(
        id: id,
        projectId: projectId,
        supplierId: supplierId,
        title: title ?? this.title,
        note: note ?? this.note,
        expectedDate: expectedDate ?? this.expectedDate,
        priority: priority ?? this.priority,
        status: status ?? this.status,
        amountEstimate: amountEstimate ?? this.amountEstimate,
        isDeleted: isDeleted ?? this.isDeleted,
        deletedAt: deletedAt ?? this.deletedAt,
        createdAt: createdAt,
        resolvedAt: resolvedAt ?? this.resolvedAt,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'project_id': projectId,
        'supplier_id': supplierId,
        'title': title,
        'note': note,
        'expected_date': expectedDate?.toUtc().toIso8601String(),
        'priority': priority.db,
        'status': status.db,
        'amount_estimate': amountEstimate,
        'is_deleted': isDeleted ? 1 : 0,
        'deleted_at': deletedAt?.toUtc().toIso8601String(),
        'created_at': createdAt.toUtc().toIso8601String(),
        'resolved_at': resolvedAt?.toUtc().toIso8601String(),
      };

  factory FollowUp.fromMap(Map<String, Object?> m) => FollowUp(
        id: m['id'] as String,
        projectId: m['project_id'] as String?,
        supplierId: m['supplier_id'] as String?,
        title: m['title'] as String,
        note: m['note'] as String?,
        expectedDate: m['expected_date'] == null
            ? null
            : DateTime.parse(m['expected_date'] as String),
        priority: FollowUpPriorityX.fromDb(m['priority'] as String),
        status: FollowUpStatusX.fromDb(m['status'] as String),
        amountEstimate: (m['amount_estimate'] as num?)?.toDouble(),
        isDeleted: ((m['is_deleted'] as num?)?.toInt() ?? 0) == 1,
        deletedAt: m['deleted_at'] == null
            ? null
            : DateTime.parse(m['deleted_at'] as String),
        createdAt: DateTime.parse(m['created_at'] as String),
        resolvedAt: m['resolved_at'] == null
            ? null
            : DateTime.parse(m['resolved_at'] as String),
      );
}
