import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/error_reporter.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';
import 'package:bismillah_constructions/desktop/desktop_shell.dart';
import 'package:bismillah_constructions/desktop/desktop_theme.dart';

/// Root of the desktop app. Shares the same real-time cloud sync as mobile
/// when the build supplies the Supabase dart-defines; runs local-only
/// otherwise (the wiring providers are inert because `SyncService.start()`
/// short-circuits when `SupabaseConfig.configured` is false).
class DesktopApp extends ConsumerWidget {
  const DesktopApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly start sync, push local mutations up, and pull remote changes
    // into the UI live — mirrors the mobile wiring in BismillahApp.
    ref.watch(syncServiceFutureProvider);
    ref.watch(commitSyncWiringProvider);
    ref.watch(remoteRefreshWiringProvider);

    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Bismillah Constructions',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: ErrorReporter.messengerKey,
      navigatorKey: ErrorReporter.navigatorKey,
      themeMode: mode,
      theme: buildDesktopTheme(brightness: Brightness.light),
      darkTheme: buildDesktopTheme(brightness: Brightness.dark),
      home: const DesktopShell(),
    );
  }
}
