import 'package:flutter/foundation.dart';

/// Increment this notifier to force a full ProviderScope teardown and
/// rebuild — effectively a soft in-process app restart. Used by the
/// auto-restore flow after a backup has been copied over the DB file.
final appRestartNotifier = ValueNotifier<int>(0);

void restartApp() => appRestartNotifier.value++;
