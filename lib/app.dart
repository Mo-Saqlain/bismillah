import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/error_reporter.dart';
import 'core/theme.dart';
import 'features/common/restore_gateway.dart';
import 'providers/providers.dart';

class BismillahApp extends ConsumerWidget {
  const BismillahApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly start the sync service.
    ref.watch(syncServiceFutureProvider);
    // Cold-boot silent backup (>6h since last).
    ref.watch(backupBootCheckProvider);
    // Wire every transaction commit to a debounced cloud + Supabase sync.
    ref.watch(commitSyncWiringProvider);

    final mode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: 'Bismillah',
      debugShowCheckedModeBanner: false,
      // Global key so [ErrorReporter] can pop SnackBars from anywhere
      // (including async error handlers that have no BuildContext).
      scaffoldMessengerKey: ErrorReporter.messengerKey,
      // Navigator key so the SnackBar's "Details" dialog opens under the
      // Navigator (the messenger context alone sits above it and can't).
      navigatorKey: ErrorReporter.navigatorKey,
      themeMode: mode,
      theme: buildTheme(brightness: Brightness.light),
      darkTheme: buildTheme(brightness: Brightness.dark),
      // Clamp the OS font-scale. A phone set to a large "Font size" /
      // "Display size" pushes textScaler past 1.0, which blows fixed rows and
      // cards out of shape (the "looks horrendous when zoomed in" report). We
      // honour larger text up to 1.3×, past which the layout can't stay legible.
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
