import 'dart:convert';

class AppUser {
  final String id;
  final String username;
  final String passwordHash;
  final String role; // 'admin' or 'user'
  final String status; // 'active' or 'revoked'
  final String createdAt;
  final String updatedAt;
  final int isDeleted;
  final String? tenantId;

  const AppUser({
    required this.id,
    required this.username,
    required this.passwordHash,
    this.role = 'user',
    this.status = 'active',
    required this.createdAt,
    required this.updatedAt,
    this.isDeleted = 0,
    this.tenantId,
  });

  bool get isAdmin => role == 'admin';
  bool get isActive => status == 'active' && isDeleted == 0;

  static String hashPassword(String password) {
    final bytes = utf8.encode('bismillah_salt_2026_$password');
    int hash = 0x811c9dc5;
    for (var b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'username': username,
        'password_hash': passwordHash,
        'role': role,
        'status': status,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'is_deleted': isDeleted,
        'tenant_id': tenantId,
      };

  factory AppUser.fromMap(Map<String, dynamic> map) => AppUser(
        id: map['id'] as String,
        username: map['username'] as String,
        passwordHash: map['password_hash'] as String,
        role: map['role'] as String? ?? 'user',
        status: map['status'] as String? ?? 'active',
        createdAt: map['created_at'] as String,
        updatedAt: map['updated_at'] as String? ?? map['created_at'] as String,
        isDeleted: map['is_deleted'] as int? ?? 0,
        tenantId: map['tenant_id'] as String?,
      );
}
