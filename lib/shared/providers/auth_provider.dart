import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/data/models/app_user.dart';
import 'package:bismillah_constructions/shared/data/repositories/user_repository.dart';
import 'package:bismillah_constructions/shared/providers/db_providers.dart';
import 'package:bismillah_constructions/shared/providers/entity_providers.dart';
import 'package:bismillah_constructions/shared/providers/sync_providers.dart';

/// Provider for UserRepository
final userRepoProvider = FutureProvider<UserRepository>((ref) async {
  final db = await ref.watch(dbProvider.future);
  return UserRepository(db);
});

/// Bumping this version forces user list refetches across the app
final userVersionProvider = StateProvider<int>((ref) => 0);

/// Current logged in user notifier
class AuthStateNotifier extends StateNotifier<AsyncValue<AppUser?>> {
  AuthStateNotifier(this._ref) : super(const AsyncValue.loading()) {
    _initSession();
  }

  final Ref _ref;

  Future<void> _initSession() async {
    try {
      final repo = await _ref.read(userRepoProvider.future);
      final entityRepo = await _ref.read(entityRepoProvider.future);
      
      final activeUserId = await entityRepo.getSetting('active_user_id');
      if (activeUserId != null && activeUserId.isNotEmpty) {
        final user = await repo.getUserById(activeUserId);
        if (user != null && user.isActive) {
          state = AsyncValue.data(user);
          return;
        }
      }
      
      // Default: no user logged in
      state = const AsyncValue.data(null);
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }

  Future<bool> login(String username, String password) async {
    state = const AsyncValue.loading();
    try {
      final repo = await _ref.read(userRepoProvider.future);
      final user = await repo.validateCredentials(username, password);

      if (user == null) {
        state = const AsyncValue.data(null);
        throw Exception('Invalid username or password.');
      }

      if (user.status == 'revoked') {
        state = const AsyncValue.data(null);
        throw Exception('Your account access has been revoked. Contact administrator.');
      }

      // Persist session
      final entityRepo = await _ref.read(entityRepoProvider.future);
      await entityRepo.setSetting('active_user_id', user.id);

      state = AsyncValue.data(user);
      return true;
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
      rethrow;
    }
  }

  Future<void> logout() async {
    try {
      final entityRepo = await _ref.read(entityRepoProvider.future);
      await entityRepo.setSetting('active_user_id', '');
    } catch (_) {}
    state = const AsyncValue.data(null);
  }

  void refreshUser(AppUser updated) {
    state = AsyncValue.data(updated);
  }
}

final authNotifierProvider =
    StateNotifierProvider<AuthStateNotifier, AsyncValue<AppUser?>>((ref) {
  return AuthStateNotifier(ref);
});

/// Easy accessor for current logged in AppUser
final currentUserProvider = Provider<AppUser?>((ref) {
  return ref.watch(authNotifierProvider).valueOrNull;
});

/// Pending access requests count provider
final pendingRequestsCountProvider = FutureProvider<int>((ref) async {
  ref.watch(userVersionProvider);
  // Also watch cloud data changes so new sync pulls update pending count live
  ref.watch(remoteRefreshWiringProvider);
  final repo = await ref.watch(userRepoProvider.future);
  return repo.getPendingRequestsCount();
});
