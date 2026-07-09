import '../../core/constants.dart';

/// Persistent audit entry for any edit/delete/archive on app data.
class ChangeLog {
  final String id;
  final String entityType; // 'journal_entry' | 'project' | 'customer' | ...
  final String entityId;
  final ChangeAction action;
  final String? originalData;
  final String? newData;
  final String? note;
  final String? deviceId;
  final DateTime timestamp;

  const ChangeLog({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.action,
    this.originalData,
    this.newData,
    this.note,
    this.deviceId,
    required this.timestamp,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'entity_type': entityType,
        'entity_id': entityId,
        'action': action.db,
        'original_data': originalData,
        'new_data': newData,
        'note': note,
        'device_id': deviceId,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  factory ChangeLog.fromMap(Map<String, Object?> m) => ChangeLog(
        id: m['id'] as String,
        entityType: m['entity_type'] as String,
        entityId: m['entity_id'] as String,
        action: ChangeActionX.fromDb(m['action'] as String),
        originalData: m['original_data'] as String?,
        newData: m['new_data'] as String?,
        note: m['note'] as String?,
        deviceId: m['device_id'] as String?,
        timestamp: DateTime.parse(m['timestamp'] as String),
      );
}
