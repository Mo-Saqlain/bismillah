import 'package:flutter/material.dart';

/// Lightweight in-process error log so the test-phase user can see what
/// went wrong without hooking up Sentry / Crashlytics / cloud logs.
///
/// How it works:
///   1. [main] wires `FlutterError.onError` and `PlatformDispatcher.onError`
///      to call [ErrorReporter.report]. Anywhere else in the app can also
///      call it explicitly to surface a caught error.
///   2. [report] adds the error to an in-memory ring buffer and pops a
///      SnackBar via [globalScaffoldMessengerKey] so it's visible *now*.
///   3. The Settings screen has a "Recent Errors" entry that shows the
///      full list (timestamp + message + stack) so the user can come back
///      to it later when collecting bug reports.
class ErrorReporter {
  ErrorReporter._();

  /// Maximum number of errors retained in memory. Old ones drop off the
  /// front. Sized small because the UI shows them as a list — a user
  /// drowning in 500 errors gets no value from the 501st.
  static const _maxRetained = 100;

  /// In-memory ring buffer of recent errors, newest first. Wrapped in a
  /// [ValueNotifier] so the Settings screen can rebuild reactively.
  static final ValueNotifier<List<ErrorRecord>> recent =
      ValueNotifier(<ErrorRecord>[]);

  /// Set by [BismillahApp] so error reports can pop SnackBars without
  /// needing a [BuildContext].
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// Add an error to the log and surface it as a SnackBar (if a messenger
  /// is mounted). Safe to call from any isolate context — falls back to
  /// silent storage if no UI is up yet.
  static void report(
    Object error, {
    StackTrace? stack,
    String? source,
  }) {
    final rec = ErrorRecord(
      timestamp: DateTime.now(),
      message: error.toString(),
      stack: stack?.toString(),
      source: source,
    );

    // Prepend so newest is at index 0 (matches what the UI expects).
    final next = [rec, ...recent.value];
    if (next.length > _maxRetained) {
      next.removeRange(_maxRetained, next.length);
    }
    recent.value = next;

    _showSnackBar(rec);
  }

  /// Clear the in-memory log. Called from the "Clear" button on the
  /// Recent Errors screen.
  static void clear() {
    recent.value = const [];
  }

  static void _showSnackBar(ErrorRecord rec) {
    final messenger = messengerKey.currentState;
    if (messenger == null) return; // UI not yet attached

    // Truncate to one line for the bar — full text is in the Errors screen.
    final firstLine = rec.message.split('\n').first;
    final preview =
        firstLine.length > 90 ? '${firstLine.substring(0, 90)}…' : firstLine;

    messenger.showSnackBar(
      SnackBar(
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                preview,
                style: const TextStyle(color: Colors.white),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'Details',
          textColor: Colors.white,
          onPressed: () {
            final ctx = messenger.context;
            showDialog<void>(
              context: ctx,
              builder: (_) => AlertDialog(
                icon: Icon(Icons.error_outline,
                    color: Colors.red.shade700, size: 36),
                title: const Text('Error details'),
                content: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (rec.source != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text('Source: ${rec.source}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      Text(rec.message,
                          style:
                              const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      if (rec.stack != null) ...[
                        const SizedBox(height: 12),
                        const Text('Stack:',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(rec.stack!,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 10)),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class ErrorRecord {
  final DateTime timestamp;
  final String message;
  final String? stack;

  /// Optional human label like 'FlutterError', 'Async', 'Backup' — handy
  /// when filtering the list later.
  final String? source;

  const ErrorRecord({
    required this.timestamp,
    required this.message,
    this.stack,
    this.source,
  });
}
