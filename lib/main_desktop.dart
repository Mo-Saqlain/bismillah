import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bismillah_constructions/shared/core/app_restart.dart';
import 'package:bismillah_constructions/shared/core/error_reporter.dart';
import 'package:bismillah_constructions/desktop/desktop_app.dart';

/// Desktop (Windows) entrypoint. Build/run with:
///   flutter run -d windows -t lib/desktop/desktop_main.dart
///
/// Deliberately does NOT initialise Supabase or wire cloud sync — the
/// desktop build is local-only. The DB opens through FFI automatically
/// (see [LocalDb.open], which calls `sqfliteFfiInit` on Windows/Linux).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Route framework + async errors into the in-memory reporter (Settings →
  // Error Log surfaces them) and show a SnackBar so nothing fails silently.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    ErrorReporter.report(
      details.exceptionAsString(),
      stack: details.stack,
      source: 'FlutterError',
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    ErrorReporter.report(error, stack: stack, source: 'Async');
    return true;
  };
  ErrorWidget.builder = (details) {
    ErrorReporter.report(
      details.exceptionAsString(),
      stack: details.stack,
      source: 'ErrorWidget',
    );
    return _ErrorCard(message: details.exceptionAsString());
  };

  runApp(
    ValueListenableBuilder<int>(
      valueListenable: appRestartNotifier,
      builder: (context, count, child) => ProviderScope(
        key: ValueKey(count),
        child: const DesktopApp(),
      ),
    ),
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 12),
            const Text('Something went wrong',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.red)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.red)),
          ],
        ),
      ),
    );
  }
}
