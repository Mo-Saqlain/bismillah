import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/error_reporter.dart';
import 'package:bismillah_constructions/shared/providers/providers.dart';
import 'package:bismillah_constructions/desktop/desktop_shell.dart';
import 'package:bismillah_constructions/desktop/desktop_theme.dart';

class DesktopApp extends ConsumerWidget {
  const DesktopApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);

    // Eagerly start sync ONLY when authenticated
    if (user != null) {
      ref.watch(syncServiceFutureProvider);
      ref.watch(commitSyncWiringProvider);
      ref.watch(remoteRefreshWiringProvider);
    }

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
