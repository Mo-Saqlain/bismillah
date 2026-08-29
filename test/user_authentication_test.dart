import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:bismillah_constructions/shared/data/db/local_db.dart';
import 'package:bismillah_constructions/shared/data/models/app_user.dart';
import 'package:bismillah_constructions/shared/data/repositories/user_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late UserRepository userRepo;

  setUp(() async {
    db = await openDatabase(inMemoryDatabasePath, version: 21,
        onCreate: (d, v) async {
      await LocalDb.instance.applySchemaForTests(d);
    });
    userRepo = UserRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('Superuser admin account is seeded on schema creation', () async {
    final admin = await userRepo.getUserByUsername('admin');
    expect(admin, isNotNull);
    expect(admin!.username, equals('admin'));
    expect(admin.role, equals('admin'));

    final valid = await userRepo.validateCredentials('admin', 'Tech@123');
    expect(valid, isNotNull);
    expect(valid!.id, equals(admin.id));

    final invalid = await userRepo.validateCredentials('admin', 'WrongPass');
    expect(invalid, isNull);
  });

  test('User creation and validation flow', () async {
    final newUser = await userRepo.createUser(
      username: 'site_supervisor',
      password: 'SuperPassword123',
      role: 'user',
    );

    expect(newUser.username, equals('site_supervisor'));
    expect(newUser.role, equals('user'));

    final authenticated =
        await userRepo.validateCredentials('site_supervisor', 'SuperPassword123');
    expect(authenticated, isNotNull);
    expect(authenticated!.id, equals(newUser.id));
  });

  test('Access request creation and approval workflow', () async {
    final req = await userRepo.createAccessRequest(
      username: 'new_contractor',
      fullName: 'Tariq Mahmood',
      phoneOrEmail: '0300-9998877',
    );

    expect(req.username, equals('new_contractor'));
    expect(req.status, equals('pending'));

    final count = await userRepo.getPendingRequestsCount();
    expect(count, equals(1));

    // Admin approves request
    await userRepo.createUser(
      username: req.username,
      password: 'ApprovedPassword!1',
      role: 'user',
    );
    await userRepo.updateAccessRequestStatus(req.id, 'approved');

    final remainingCount = await userRepo.getPendingRequestsCount();
    expect(remainingCount, equals(0));

    final user =
        await userRepo.validateCredentials('new_contractor', 'ApprovedPassword!1');
    expect(user, isNotNull);
  });

  test('Revoking user access prevents login', () async {
    final user = await userRepo.createUser(
      username: 'sub_user',
      password: 'SecretPassword',
    );

    expect(user.status, equals('active'));

    // Admin revokes access
    await userRepo.updateUserStatus(user.id, 'revoked');

    final updated = await userRepo.getUserByUsername('sub_user');
    expect(updated!.status, equals('revoked'));
    expect(updated.isActive, isFalse);
  });
}
