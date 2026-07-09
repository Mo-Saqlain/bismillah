import '../../core/constants.dart';

class Project {
  final String id;
  final String name;
  final ProjectModel model;
  final ProjectStatus status;
  final DateTime createdAt;

  /// Free-text client name. Replaces the previous customer-FK relation; the
  /// user explicitly does NOT want a separate Customer / Client entity.
  final String? clientName;

  final String? siteAddress;
  final double? budget;
  final String? projectManager;

  /// Client's WhatsApp number for the post-transaction send prompt on
  /// project receipts. Free-text; normalized to international format at
  /// send time. Optional — a receipt with no number just skips the prompt.
  final String? whatsapp;

  /// Service fee % for Labour-Rate model (e.g. 5 means 5% of total spend).
  /// Used when [serviceFeeType] is [ServiceFeeType.percent].
  final double? serviceFeePercent;

  /// How the Labour-Rate service fee is calculated — a percentage of spend
  /// or a flat amount. Defaults to percentage for backwards compatibility.
  final ServiceFeeType serviceFeeType;

  /// Flat service fee in rupees, used when [serviceFeeType] is
  /// [ServiceFeeType.fixed]. Earned regardless of how much is spent.
  final double? serviceFeeAmount;

  /// v14: owner-entered rough progress estimate (0..100). Intentionally not
  /// derived from BOQ / quantities — this is a gut-feel number used for
  /// the dashboard progress bar and forecasting context.
  final int completionPercent;

  /// 1 = archived (soft delete). Data preserved for legal evidence.
  final int isArchived;
  final DateTime? archivedAt;

  const Project({
    required this.id,
    required this.name,
    required this.model,
    required this.status,
    required this.createdAt,
    this.clientName,
    this.siteAddress,
    this.budget,
    this.projectManager,
    this.whatsapp,
    this.serviceFeePercent,
    this.serviceFeeType = ServiceFeeType.percent,
    this.serviceFeeAmount,
    this.completionPercent = 0,
    this.isArchived = 0,
    this.archivedAt,
  });

  bool get archived => isArchived == 1;

  /// The contractor's service fee for this (Labour-Rate) project given the
  /// total spent on the job. Single source of truth for the fee math:
  ///   * [ServiceFeeType.fixed]   → the flat [serviceFeeAmount], no matter
  ///     what was spent.
  ///   * [ServiceFeeType.percent] → [serviceFeePercent]% of [totalSpent].
  double serviceFeeOn(double totalSpent) => switch (serviceFeeType) {
        ServiceFeeType.fixed => serviceFeeAmount ?? 0,
        ServiceFeeType.percent => totalSpent * (serviceFeePercent ?? 0) / 100,
      };

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'model': model.db,
        'status': status.db,
        'created_at': createdAt.toUtc().toIso8601String(),
        'client_name': clientName,
        'site_address': siteAddress,
        'budget': budget,
        'project_manager': projectManager,
        'whatsapp': whatsapp,
        'service_fee_percent': serviceFeePercent,
        'service_fee_type': serviceFeeType.db,
        'service_fee_amount': serviceFeeAmount,
        'completion_percent': completionPercent,
        'is_archived': isArchived,
        'archived_at': archivedAt?.toUtc().toIso8601String(),
      };

  factory Project.fromMap(Map<String, Object?> m) => Project(
        id: m['id'] as String,
        name: m['name'] as String,
        model: ProjectModelX.fromDb(m['model'] as String),
        status: ProjectStatusX.fromDb(m['status'] as String),
        createdAt: DateTime.parse(m['created_at'] as String),
        clientName: m['client_name'] as String?,
        siteAddress: m['site_address'] as String?,
        budget: (m['budget'] as num?)?.toDouble(),
        projectManager: m['project_manager'] as String?,
        whatsapp: m['whatsapp'] as String?,
        serviceFeePercent: (m['service_fee_percent'] as num?)?.toDouble(),
        serviceFeeType: ServiceFeeTypeX.fromDb(m['service_fee_type'] as String?),
        serviceFeeAmount: (m['service_fee_amount'] as num?)?.toDouble(),
        completionPercent: (m['completion_percent'] as num?)?.toInt() ?? 0,
        isArchived: (m['is_archived'] as int?) ?? 0,
        archivedAt: m['archived_at'] == null
            ? null
            : DateTime.parse(m['archived_at'] as String),
      );

  Project copyWith({
    String? name,
    ProjectModel? model,
    ProjectStatus? status,
    String? clientName,
    String? siteAddress,
    double? budget,
    String? projectManager,
    String? whatsapp,
    double? serviceFeePercent,
    ServiceFeeType? serviceFeeType,
    double? serviceFeeAmount,
    int? completionPercent,
    int? isArchived,
    DateTime? archivedAt,
  }) =>
      Project(
        id: id,
        name: name ?? this.name,
        model: model ?? this.model,
        status: status ?? this.status,
        createdAt: createdAt,
        clientName: clientName ?? this.clientName,
        siteAddress: siteAddress ?? this.siteAddress,
        budget: budget ?? this.budget,
        projectManager: projectManager ?? this.projectManager,
        whatsapp: whatsapp ?? this.whatsapp,
        serviceFeePercent: serviceFeePercent ?? this.serviceFeePercent,
        serviceFeeType: serviceFeeType ?? this.serviceFeeType,
        serviceFeeAmount: serviceFeeAmount ?? this.serviceFeeAmount,
        completionPercent: completionPercent ?? this.completionPercent,
        isArchived: isArchived ?? this.isArchived,
        archivedAt: archivedAt ?? this.archivedAt,
      );
}
