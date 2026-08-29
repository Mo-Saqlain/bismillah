import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'package:bismillah_constructions/shared/data/models/access_request.dart';
import 'package:bismillah_constructions/shared/data/models/app_user.dart';

class UserRepository {
  UserRepository(this._db);
  final Database _db;
  static const _uuid = Uuid();

  /// Retrieve all non-deleted users
  Future<List<AppUser>> getUsers() async {
    final rows = await _db.query(
      'app_users',
      where: 'is_deleted = 0',
      orderBy: 'username ASC',
    );
    return rows.map(AppUser.fromMap).toList();
  }

  /// Get user by username
  Future<AppUser?> getUserByUsername(String username) async {
    final rows = await _db.query(
      'app_users',
      where: 'LOWER(username) = LOWER(?) AND is_deleted = 0',
      whereArgs: [username.trim()],
    );
    if (rows.isEmpty) return null;
    return AppUser.fromMap(rows.first);
  }

  /// Get user by ID
  Future<AppUser?> getUserById(String id) async {
    final rows = await _db.query(
      'app_users',
      where: 'id = ? AND is_deleted = 0',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return AppUser.fromMap(rows.first);
  }

  /// Validates user credentials. Returns user if valid, null otherwise.
  Future<AppUser?> validateCredentials(String username, String password) async {
    final trimmed = username.trim();
    final user = await getUserByUsername(trimmed);
    if (user == null) return null;

    final inputHash = AppUser.hashPassword(password);
    if (user.passwordHash == inputHash) {
      return user;
    }
    return null;
  }

  /// Creates a new user account
  Future<AppUser> createUser({
    required String username,
    required String password,
    String role = 'user',
    String? tenantId,
  }) async {
    final trimmed = username.trim();
    final existing = await getUserByUsername(trimmed);
    if (existing != null) {
      throw Exception('Username "$trimmed" is already taken.');
    }

    final now = DateTime.now().toIso8601String();
    final user = AppUser(
      id: _uuid.v4(),
      username: trimmed,
      passwordHash: AppUser.hashPassword(password),
      role: role,
      status: 'active',
      createdAt: now,
      updatedAt: now,
      tenantId: tenantId,
    );

    await _db.insert('app_users', user.toMap());
    return user;
  }

  /// Update user status ('active' or 'revoked')
  Future<void> updateUserStatus(String userId, String status) async {
    final now = DateTime.now().toIso8601String();
    await _db.update(
      'app_users',
      {
        'status': status,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  /// Update user role ('admin' or 'user')
  Future<void> updateUserRole(String userId, String role) async {
    final now = DateTime.now().toIso8601String();
    await _db.update(
      'app_users',
      {
        'role': role,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  /// Update user password
  Future<void> updateUserPassword(String userId, String newPassword) async {
    final now = DateTime.now().toIso8601String();
    await _db.update(
      'app_users',
      {
        'password_hash': AppUser.hashPassword(newPassword),
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  /// Soft-delete user
  Future<void> deleteUser(String userId) async {
    final now = DateTime.now().toIso8601String();
    await _db.update(
      'app_users',
      {
        'is_deleted': 1,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  // ── Access Requests ──────────────────────────────────────────────────

  /// Get all access requests
  Future<List<AccessRequest>> getAccessRequests() async {
    final rows = await _db.query(
      'access_requests',
      where: 'is_deleted = 0',
      orderBy: 'created_at DESC',
    );
    return rows.map(AccessRequest.fromMap).toList();
  }

  /// Get pending access request count
  Future<int> getPendingRequestsCount() async {
    final rows = await _db.rawQuery(
      "SELECT COUNT(*) AS c FROM access_requests WHERE status = 'pending' AND is_deleted = 0",
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// Create access request
  Future<AccessRequest> createAccessRequest({
    required String username,
    String? fullName,
    String? phoneOrEmail,
    String? tenantId,
  }) async {
    final trimmed = username.trim();
    final now = DateTime.now().toIso8601String();
    final req = AccessRequest(
      id: _uuid.v4(),
      username: trimmed,
      fullName: fullName?.trim().isEmpty == true ? null : fullName?.trim(),
      phoneOrEmail: phoneOrEmail?.trim().isEmpty == true ? null : phoneOrEmail?.trim(),
      status: 'pending',
      createdAt: now,
      updatedAt: now,
      tenantId: tenantId,
    );

    await _db.insert('access_requests', req.toMap());
    return req;
  }

  /// Update access request status ('approved' or 'rejected')
  Future<void> updateAccessRequestStatus(String requestId, String status) async {
    final now = DateTime.now().toIso8601String();
    await _db.update(
      'access_requests',
      {
        'status': status,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [requestId],
    );
  }
}
