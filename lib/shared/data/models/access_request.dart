class AccessRequest {
  final String id;
  final String username;
  final String? fullName;
  final String? phoneOrEmail;
  final String status; // 'pending', 'approved', 'rejected'
  final String createdAt;
  final String updatedAt;
  final int isDeleted;
  final String? tenantId;

  const AccessRequest({
    required this.id,
    required this.username,
    this.fullName,
    this.phoneOrEmail,
    this.status = 'pending',
    required this.createdAt,
    required this.updatedAt,
    this.isDeleted = 0,
    this.tenantId,
  });

  bool get isPending => status == 'pending';

  Map<String, dynamic> toMap() => {
        'id': id,
        'username': username,
        'full_name': fullName,
        'phone_or_email': phoneOrEmail,
        'status': status,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'is_deleted': isDeleted,
        'tenant_id': tenantId,
      };

  factory AccessRequest.fromMap(Map<String, dynamic> map) => AccessRequest(
        id: map['id'] as String,
        username: map['username'] as String,
        fullName: map['full_name'] as String?,
        phoneOrEmail: map['phone_or_email'] as String?,
        status: map['status'] as String? ?? 'pending',
        createdAt: map['created_at'] as String,
        updatedAt: map['updated_at'] as String? ?? map['created_at'] as String,
        isDeleted: map['is_deleted'] as int? ?? 0,
        tenantId: map['tenant_id'] as String?,
      );
}
