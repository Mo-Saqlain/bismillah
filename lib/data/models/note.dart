/// Entity types a [Note] can attach to. Stored as the enum name in the
/// `notes.entity_type` column — keep these strings stable across releases.
enum NoteEntityType { project, supplier }

extension NoteEntityTypeX on NoteEntityType {
  String get db => name;
  String get label => switch (this) {
        NoteEntityType.project => 'Project',
        NoteEntityType.supplier => 'Supplier',
      };
  static NoteEntityType fromDb(String s) =>
      NoteEntityType.values.firstWhere((v) => v.name == s,
          orElse: () => NoteEntityType.project);
}

/// Free-text memory attached to a project or supplier. Soft-delete is
/// supported so accidental taps can be restored from the change-log /
/// note-history surface.
class Note {
  final String id;
  final NoteEntityType entityType;
  final String entityId;
  final String body;
  final bool isPinned;
  final bool isDeleted;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime? updatedAt;

  const Note({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.body,
    required this.createdAt,
    this.isPinned = false,
    this.isDeleted = false,
    this.deletedAt,
    this.updatedAt,
  });

  Note copyWith({
    String? body,
    bool? isPinned,
    bool? isDeleted,
    DateTime? deletedAt,
    DateTime? updatedAt,
  }) =>
      Note(
        id: id,
        entityType: entityType,
        entityId: entityId,
        body: body ?? this.body,
        isPinned: isPinned ?? this.isPinned,
        isDeleted: isDeleted ?? this.isDeleted,
        deletedAt: deletedAt ?? this.deletedAt,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toMap() {
    final m = <String, Object?>{
      'id': id,
      'entity_type': entityType.db,
      'entity_id': entityId,
      'body': body,
      'is_pinned': isPinned ? 1 : 0,
      'is_deleted': isDeleted ? 1 : 0,
      'deleted_at': deletedAt?.toUtc().toIso8601String(),
      'created_at': createdAt.toUtc().toIso8601String(),
    };
    // `updated_at` is managed by SQLite: the column DEFAULT supplies
    // the initial value on INSERT, and an AFTER UPDATE trigger keeps
    // it fresh thereafter. Sending an explicit NULL here would trip
    // the NOT NULL constraint, so we only forward the value when we
    // actually have one.
    if (updatedAt != null) {
      m['updated_at'] = updatedAt!.toUtc().toIso8601String();
    }
    return m;
  }

  factory Note.fromMap(Map<String, Object?> m) => Note(
        id: m['id'] as String,
        entityType: NoteEntityTypeX.fromDb(m['entity_type'] as String),
        entityId: m['entity_id'] as String,
        body: m['body'] as String,
        isPinned: ((m['is_pinned'] as num?)?.toInt() ?? 0) == 1,
        isDeleted: ((m['is_deleted'] as num?)?.toInt() ?? 0) == 1,
        deletedAt: m['deleted_at'] == null
            ? null
            : DateTime.parse(m['deleted_at'] as String),
        createdAt: DateTime.parse(m['created_at'] as String),
        updatedAt: m['updated_at'] == null
            ? null
            : DateTime.parse(m['updated_at'] as String),
      );
}
