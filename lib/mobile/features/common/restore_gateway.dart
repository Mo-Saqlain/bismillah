import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/providers/providers.dart';
import 'package:bismillah_constructions/mobile/features/auth/login_screen.dart';
import 'package:bismillah_constructions/mobile/features/home/home_screen.dart';

/// Startup gate that sits in front of [HomeScreen] and [LoginScreen].
///
/// Ensures local DB is open and routes immediately to [LoginScreen] if no user
/// is authenticated, or [HomeScreen] if active session exists.
class RestoreGateway extends ConsumerStatefulWidget {
  const RestoreGateway({super.key});

  @override
  ConsumerState<RestoreGateway> createState() => _RestoreGatewayState();
}

class _RestoreGatewayState extends ConsumerState<RestoreGateway> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startup());
  }

  Future<void> _startup() async {
    try {
      await ref.read(dbProvider.future);
    } catch (_) {}
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final authState = ref.watch(authNotifierProvider);

    return authState.when(
      data: (user) {
        if (user == null) {
          return const LoginScreen();
        }
        return const HomeScreen();
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const LoginScreen(),
    );
  }
}
