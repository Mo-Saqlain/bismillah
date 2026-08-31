import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/error_reporter.dart';
import 'package:bismillah_constructions/shared/core/theme.dart';
import 'package:bismillah_constructions/mobile/features/common/restore_gateway.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';

class BismillahApp extends ConsumerWidget {
  const BismillahApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);

    // Eagerly start sync service & listeners ONLY when a user is logged in
    if (user != null) {
      ref.watch(syncServiceFutureProvider);
      ref.watch(backupBootCheckProvider);
      ref.watch(commitSyncWiringProvider);
      ref.watch(remoteRefreshWiringProvider);
    }

    final mode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: 'Bismillah',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: ErrorReporter.messengerKey,
      navigatorKey: ErrorReporter.navigatorKey,
      themeMode: mode,
      theme: buildTheme(brightness: Brightness.light),
      darkTheme: buildTheme(brightness: Brightness.dark),
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler
                .clamp(minScaleFactor: 1.0, maxScaleFactor: 1.3),
          ),
          child: child!,
        );
      },
      home: const RestoreGateway(),
    );
  }
}
