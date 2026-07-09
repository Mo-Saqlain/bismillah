/// One row in the unified ledger.
///
/// Every transaction produces exactly two rows that share `transactionId`:
/// one with `debit > 0, credit == 0` and one with `credit > 0, debit == 0`.
class JournalEntry {
  final String id;
  final String transactionId;
  final String accountId;
  final String? projectId;
  final String? supplierId;
  final double debit;
  final double credit;
  final String? description;
  final DateTime createdAt;

  /// Local-only flag — 0 = pending, 1 = pushed to Supabase.
  final int synced;

  /// Soft-delete flag. 1 = removed from active balance but visible in archive.
  final int isDeleted;
  final DateTime? deletedAt;

  const JournalEntry({
    required this.id,
    required this.transactionId,
    required this.accountId,
    this.projectId,
    this.supplierId,
    required this.debit,
    required this.credit,
    this.description,
    required this.createdAt,
    this.synced = 0,
    this.isDeleted = 0,
    this.deletedAt,
  });

  bool get deleted => isDeleted == 1;

  Map<String, Object?> toMap() => {
        'id': id,
        'transaction_id': transactionId,
        'account_id': accountId,
        'project_id': projectId,
        'supplier_id': supplierId,
        'debit': debit,
        'credit': credit,
        'description': description,
        'created_at': createdAt.toUtc().toIso8601String(),
        'synced': synced,
        'is_deleted': isDeleted,
        'deleted_at': deletedAt?.toUtc().toIso8601String(),
      };

  /// Map without local-only columns — for pushing to Supabase.
  Map<String, Object?> toRemoteMap() {
    final m = Map<String, Object?>.from(toMap());
    m.remove('synced');
    m.remove('is_deleted');
    m.remove('deleted_at');
    return m;
  }

  factory JournalEntry.fromMap(Map<String, Object?> m) => JournalEntry(
        id: m['id'] as String,
        transactionId: m['transaction_id'] as String,
        accountId: m['account_id'] as String,
        projectId: m['project_id'] as String?,
        supplierId: m['supplier_id'] as String?,
        debit: (m['debit'] as num).toDouble(),
        credit: (m['credit'] as num).toDouble(),
        description: m['description'] as String?,
        createdAt: DateTime.parse(m['created_at'] as String),
        synced: (m['synced'] as int?) ?? 0,
        isDeleted: (m['is_deleted'] as int?) ?? 0,
        deletedAt: m['deleted_at'] == null
            ? null
            : DateTime.parse(m['deleted_at'] as String),
      );
}
